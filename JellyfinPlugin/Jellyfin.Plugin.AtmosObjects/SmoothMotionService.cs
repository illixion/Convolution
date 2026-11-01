using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using System.Text.RegularExpressions;
using Jellyfin.Data.Enums;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Controller.Entities;
using MediaBrowser.Controller.Library;
using MediaBrowser.Controller.MediaEncoding;
using MediaBrowser.Model.Entities;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// Smooth Motion tracks for 3D titles: the motion and disparity fields that
/// let Convolution make in-between frames for both eyes of a 3D picture from
/// one motion field (Hypnos <c>docs/plans/blu-ray-3d-smooth-motion.md</c>).
/// They come from <c>vergence analyze</c> with two Core ML models, so this
/// works on a Mac server only. A film is analysed once, a little faster than
/// real time on an M1 (16 frames a second, so a two-hour film takes about
/// 3.5 hours), one film at a time, and the result kept:
///
///   &lt;cache&gt;/smooth-motion/&lt;itemId&gt;/track.vgat     the track (about 25 KB a frame, 4 GB a film)
///   &lt;cache&gt;/smooth-motion/&lt;itemId&gt;/chunks.json    where each <see cref="ChunkSeconds"/> of it starts
///   &lt;cache&gt;/smooth-motion/&lt;itemId&gt;/failed.txt     why the last run failed
///
/// A track made elsewhere (<c>vergence analyze</c> on another Mac) can be put
/// in the folder as track.vgat; its chunk table is built on first use.
///
/// A player reads it in chunks ahead of the playhead (each chunk is the
/// track's header plus the records whose time falls in it, a track of its
/// own), so it never needs the whole file; a download takes the whole file.
///
/// Inputs: a Blu-ray (ISO or folder) is read by vergence itself, on the
/// playlist's clock as the film player plays it; a side-by-side or
/// top-and-bottom file (Jellyfin's <c>Video3DFormat</c>) is decoded by
/// ffmpeg, its eyes stacked left over right, on the file's own clock from 0.
/// An H.264 file is first copied without its SEI, because its frame-packing
/// SEI makes ffmpeg 8 and 9 fail every filter graph ("File exists", -17).
/// </summary>
public sealed partial class SmoothMotionService : IDisposable
{
    /// <summary>Seconds of track per chunk a player fetches.</summary>
    public const int ChunkSeconds = 10;

    private readonly ILibraryManager _libraryManager;
    private readonly IMediaSourceManager _mediaSourceManager;
    private readonly IMediaEncoder _encoder;
    private readonly IApplicationPaths _paths;
    private readonly ILogger<SmoothMotionService> _logger;
    /// <summary>One analysis at a time: it takes the whole Neural Engine and GPU.</summary>
    private readonly SemaphoreSlim _worker = new(1, 1);
    private readonly ConcurrentDictionary<Guid, Job> _jobs = new();
    private readonly ConcurrentDictionary<Guid, ChunkTable> _tables = new();
    private readonly CancellationTokenSource _lifetime = new();
    private readonly object _importGate = new();

    public SmoothMotionService(
        ILibraryManager libraryManager,
        IMediaSourceManager mediaSourceManager,
        IMediaEncoder mediaEncoder,
        IApplicationPaths paths,
        ILogger<SmoothMotionService> logger)
    {
        _libraryManager = libraryManager;
        _mediaSourceManager = mediaSourceManager;
        _encoder = mediaEncoder;
        _paths = paths;
        _logger = logger;
    }

    private static PluginConfiguration Config => Plugin.Instance?.Configuration ?? new PluginConfiguration();

    private string Root => Path.Combine(
        string.IsNullOrWhiteSpace(Config.CacheDirectory) ? Path.Combine(_paths.CachePath, "atmos-objects") : Config.CacheDirectory,
        "smooth-motion");

    private string ItemDirectory(Guid itemId) => Path.Combine(Root, itemId.ToString("N"));

    private string TrackPath(Guid itemId) => Path.Combine(ItemDirectory(itemId), "track.vgat");

    private string TablePath(Guid itemId) => Path.Combine(ItemDirectory(itemId), "chunks.json");

    private string FailurePath(Guid itemId) => Path.Combine(ItemDirectory(itemId), "failed.txt");

    /// <summary>The Core ML models: <c>SmoothMotionModelsPath</c>, else smooth-motion-models beside vergence.</summary>
    private string ModelsPath => string.IsNullOrWhiteSpace(Config.SmoothMotionModelsPath)
        ? Path.Combine(Path.GetDirectoryName(AtmosSceneService.VergencePath(_paths)) ?? string.Empty, "smooth-motion-models")
        : Config.SmoothMotionModelsPath;

    // MARK: Status

    /// <summary>What a client is told about an item.</summary>
    public SmoothMotionStatus GetStatus(Guid itemId)
    {
        if (_libraryManager.GetItemById(itemId) is not Video video)
        {
            return new SmoothMotionStatus("none", "not a video");
        }

        if (LoadTable(itemId) is { } table)
        {
            return new SmoothMotionStatus("ready", null)
            {
                ChunkSeconds = table.ChunkSeconds,
                Chunks = table.Chunks.Count,
                FrameRate = table.FrameRate,
                Bytes = table.Bytes
            };
        }

        if (_jobs.TryGetValue(itemId, out var job))
        {
            return new SmoothMotionStatus(job.Started ? "running" : "queued", null) { Progress = job.Progress };
        }

        if (Unsupported(video) is { } reason)
        {
            return new SmoothMotionStatus("unsupported", reason);
        }

        var failure = FailurePath(itemId);
        return File.Exists(failure)
            ? new SmoothMotionStatus("failed", File.ReadAllText(failure))
            : new SmoothMotionStatus("none", null);
    }

    /// <summary>Why this server can't analyse <paramref name="video"/>, or null when it can.</summary>
    private string? Unsupported(Video video)
    {
        if (!Config.SmoothMotion)
        {
            return "Smooth Motion analysis is turned off in the plugin's configuration";
        }

        if (!OperatingSystem.IsMacOS())
        {
            return "needs a Mac server (Core ML)";
        }

        if (!File.Exists(AtmosSceneService.VergencePath(_paths)))
        {
            return "vergence is not installed";
        }

        if (!System.IO.Directory.Exists(ModelsPath))
        {
            return "the Smooth Motion models are not installed";
        }

        return IsBluray(video) || Packing(video) is not null ? null : "not a 3D title";
    }

    private static bool IsBluray(BaseItem item) => item is Video { VideoType: VideoType.BluRay }
        or Video { VideoType: VideoType.Iso, IsoType: IsoType.BluRay };

    /// <summary>Side by side (true) or top and bottom (false) for a packed 3D file, else null.</summary>
    private static bool? Packing(Video video) => video.Video3DFormat switch
    {
        Video3DFormat.HalfSideBySide or Video3DFormat.FullSideBySide => true,
        Video3DFormat.HalfTopAndBottom or Video3DFormat.FullTopAndBottom => false,
        _ => null
    };

    // MARK: Chunks

    /// <summary>
    /// Chunk <paramref name="index"/> as a track of its own: the file's header
    /// bytes, then the byte range of its records. Null when the item has no
    /// track or the index is past its end.
    /// </summary>
    public (string Path, int HeaderLength, long Offset, long Length)? GetChunk(Guid itemId, int index)
    {
        if (LoadTable(itemId) is not { } table || index < 0 || index >= table.Chunks.Count)
        {
            return null;
        }

        var chunk = table.Chunks[index];
        return (TrackPath(itemId), table.HeaderLength, chunk[0], chunk[1]);
    }

    /// <summary>The whole track, for a download.</summary>
    public string? GetTrackPath(Guid itemId) => LoadTable(itemId) is null ? null : TrackPath(itemId);

    private ChunkTable? LoadTable(Guid itemId)
    {
        if (_tables.TryGetValue(itemId, out var cached))
        {
            return cached;
        }

        var path = TablePath(itemId);
        if (!File.Exists(TrackPath(itemId)))
        {
            return null;
        }

        if (!File.Exists(path))
        {
            return ImportTable(itemId);
        }

        try
        {
            var table = JsonSerializer.Deserialize<ChunkTable>(File.ReadAllText(path), AtmosSceneService.JsonOptions);
            if (table is not null)
            {
                _tables[itemId] = table;
            }

            return table;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>
    /// A track put in the item's folder by hand (made by <c>vergence analyze</c>
    /// on another Mac) gets its chunk table on first use; a few seconds for a film.
    /// </summary>
    private ChunkTable? ImportTable(Guid itemId)
    {
        if (_jobs.ContainsKey(itemId))
        {
            return null;
        }

        lock (_importGate)
        {
            if (_tables.TryGetValue(itemId, out var cached))
            {
                return cached;
            }

            try
            {
                var table = ChunkTable.Build(TrackPath(itemId), ChunkSeconds);
                var tmp = TablePath(itemId) + ".tmp";
                File.WriteAllText(tmp, JsonSerializer.Serialize(table, AtmosSceneService.JsonOptions));
                File.Move(tmp, TablePath(itemId), overwrite: true);
                _tables[itemId] = table;
                _logger.LogInformation("Smooth Motion: imported a track for {ItemId}, {Records} records, {Chunks} chunks", itemId, table.Records, table.Chunks.Count);
                return table;
            }
            catch (Exception e) when (e is IOException or InvalidDataException)
            {
                _logger.LogWarning("Smooth Motion: the track in {ItemId}'s folder is unreadable: {Problem}", itemId, e.Message);
                return null;
            }
        }
    }

    // MARK: Analysis

    /// <summary>Starts analysing an item in the background (after any analysis already running). False when it can't be.</summary>
    public bool Enqueue(Guid itemId, out string? reason)
    {
        reason = null;
        if (_libraryManager.GetItemById(itemId) is not Video video)
        {
            reason = "not a video";
            return false;
        }

        if ((reason = Unsupported(video)) is not null)
        {
            return false;
        }

        if (LoadTable(itemId) is not null || _jobs.ContainsKey(itemId))
        {
            return true;
        }

        var job = new Job();
        if (_jobs.TryAdd(itemId, job))
        {
            _ = Task.Run(async () =>
            {
                try
                {
                    await WorkAsync(itemId, job, _lifetime.Token).ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                }
            });
        }

        return true;
    }

    /// <summary>Every 3D title without a track, for the scheduled task.</summary>
    public IReadOnlyList<Video> Candidates() => _libraryManager
        .GetItemList(new InternalItemsQuery
        {
            IncludeItemTypes = [BaseItemKind.Movie, BaseItemKind.Episode],
            IsVirtualItem = false,
            Recursive = true
        })
        .OfType<Video>()
        .Where(v => Packing(v) is not null || (IsBluray(v) && v.Video3DFormat is not null))
        .Where(v => LoadTable(v.Id) is null && !File.Exists(FailurePath(v.Id)))
        .ToList();

    /// <summary>Analyses the item, waiting for any analysis before it; true when a track was made.</summary>
    public async Task<bool> AnalyzeAsync(Guid itemId, CancellationToken ct)
    {
        var job = new Job();
        return _jobs.TryAdd(itemId, job) && await WorkAsync(itemId, job, ct).ConfigureAwait(false);
    }

    /// <summary>Runs a registered job once the worker is free; the job leaves <see cref="_jobs"/> when done.</summary>
    private async Task<bool> WorkAsync(Guid itemId, Job job, CancellationToken ct)
    {
        try
        {
            await _worker.WaitAsync(ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            _jobs.TryRemove(itemId, out _);
            throw;
        }

        try
        {
            if (LoadTable(itemId) is not null)
            {
                return true;
            }

            job.Started = true;
            return await RunAsync(itemId, job, ct).ConfigureAwait(false);
        }
        finally
        {
            _jobs.TryRemove(itemId, out _);
            _worker.Release();
        }
    }

    private async Task<bool> RunAsync(Guid itemId, Job job, CancellationToken ct)
    {
        if (_libraryManager.GetItemById(itemId) is not Video video || Unsupported(video) is { } reason)
        {
            return false;
        }

        var directory = ItemDirectory(itemId);
        System.IO.Directory.CreateDirectory(directory);
        var part = TrackPath(itemId) + ".part";
        TryDelete(part);
        TryDelete(FailurePath(itemId));

        var stream = _mediaSourceManager.GetMediaStreams(itemId).FirstOrDefault(s => s.Type == MediaStreamType.Video);
        var rate = stream?.RealFrameRate ?? stream?.AverageFrameRate ?? 24000f / 1001;
        var durationSeconds = (video.RunTimeTicks ?? 0) / (double)TimeSpan.TicksPerSecond;
        job.ExpectedFrames = durationSeconds * rate;
        var started = Stopwatch.StartNew();
        _logger.LogInformation("Smooth Motion: analysing {ItemId} ({Kind}, {Minutes:0} min at {Rate:0.###} fps)",
            itemId, IsBluray(video) ? "Blu-ray" : video.Video3DFormat?.ToString(), durationSeconds / 60, rate);

        string? problem;
        try
        {
            problem = IsBluray(video)
                ? await RunDiscAsync(video.Path, part, job, ct).ConfigureAwait(false)
                : await RunPackedAsync(video, stream, rate, part, job, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            TryDelete(part);
            _logger.LogInformation("Smooth Motion: analysis of {ItemId} cancelled", itemId);
            throw;
        }

        if (problem is null)
        {
            try
            {
                var table = ChunkTable.Build(part, ChunkSeconds);
                File.Move(part, TrackPath(itemId), overwrite: true);
                var tmp = TablePath(itemId) + ".tmp";
                await File.WriteAllTextAsync(tmp, JsonSerializer.Serialize(table, AtmosSceneService.JsonOptions), CancellationToken.None).ConfigureAwait(false);
                File.Move(tmp, TablePath(itemId), overwrite: true);
                _tables[itemId] = table;
                _logger.LogInformation("Smooth Motion: {ItemId} analysed in {Minutes:0} min, {Records} records, {Megabytes:0} MB, {Chunks} chunks",
                    itemId, started.Elapsed.TotalMinutes, table.Records, table.Bytes / 1e6, table.Chunks.Count);
                return true;
            }
            catch (Exception e) when (e is IOException or InvalidDataException)
            {
                problem = $"the track couldn't be read back: {e.Message}";
            }
        }

        TryDelete(part);
        await File.WriteAllTextAsync(FailurePath(itemId), problem, CancellationToken.None).ConfigureAwait(false);
        _logger.LogWarning("Smooth Motion: analysis of {ItemId} failed: {Problem}", itemId, problem);
        return false;
    }

    private Task<string?> RunDiscAsync(string discPath, string output, Job job, CancellationToken ct)
    {
        var vergence = Start(AtmosSceneService.VergencePath(_paths),
            ["analyze", discPath, "--models", ModelsPath, "--output", output], stdin: false);
        return FinishAsync([], vergence, job, ct);
    }

    private async Task<string?> RunPackedAsync(Video video, MediaStream? stream, float rate, string output, Job job, CancellationToken ct)
    {
        if (stream?.Width is not int width || stream.Height is not int height || width <= 0 || height <= 0)
        {
            return "the video's size is unknown";
        }

        var sideBySide = Packing(video) == true;
        var eyeWidth = sideBySide ? width / 2 : width;
        var eyeHeight = sideBySide ? height : height / 2;
        var ffmpeg = _encoder.EncoderPath;
        var processes = new List<Process>();
        var copies = new List<Task>();
        try
        {
            Stream decoderInput;
            string input;
            if (string.Equals(stream.Codec, "h264", StringComparison.OrdinalIgnoreCase))
            {
                var strip = Start(ffmpeg, ["-nostdin", "-v", "error", "-i", video.Path, "-map", "0:v:0",
                    "-bsf:v", "filter_units=remove_types=6", "-c:v", "copy", "-f", "matroska", "-"], stdin: false);
                processes.Add(strip);
                decoderInput = strip.StandardOutput.BaseStream;
                input = "-";
            }
            else
            {
                decoderInput = Stream.Null;
                input = video.Path;
            }

            // Left over right at one eye's stored size: a top-and-bottom picture already is.
            var args = new List<string> { "-nostdin", "-v", "error", "-i", input };
            args.AddRange(sideBySide
                ? ["-filter_complex", "[0:v:0]split[a][b];[a]crop=iw/2:ih:0:0[l];[b]crop=iw/2:ih:iw/2:0[r];[l][r]vstack[out]", "-map", "[out]"]
                : ["-map", "0:v:0"]);

            args.AddRange(["-f", "rawvideo", "-pix_fmt", "yuv420p", "-"]);
            var decoder = Start(ffmpeg, args, stdin: input == "-");
            processes.Add(decoder);
            if (input == "-")
            {
                copies.Add(Pipe(decoderInput, decoder.StandardInput.BaseStream, ct));
            }

            var vergence = Start(AtmosSceneService.VergencePath(_paths),
                ["analyze", "--raw", string.Create(CultureInfo.InvariantCulture, $"{eyeWidth}x{eyeHeight}"), "--rate", Rational(rate), "-",
                 "--models", ModelsPath, "--output", output], stdin: true);
            copies.Add(Pipe(decoder.StandardOutput.BaseStream, vergence.StandardInput.BaseStream, ct));
            var problem = await FinishAsync(processes, vergence, job, ct).ConfigureAwait(false);
            await Task.WhenAll(copies).ConfigureAwait(false);
            return problem;
        }
        finally
        {
            foreach (var process in processes)
            {
                Kill(process);
                process.Dispose();
            }
        }
    }

    /// <summary>Waits for vergence, reading its progress; the feeding processes are stopped with it.</summary>
    private async Task<string?> FinishAsync(List<Process> feeders, Process vergence, Job job, CancellationToken ct)
    {
        using var _ = vergence;
        var errors = new List<Task<string>>();
        foreach (var feeder in feeders)
        {
            errors.Add(feeder.StandardError.ReadToEndAsync(ct));
        }

        var lastLines = new Queue<string>();
        var progress = Task.Run(async () =>
        {
            while (await vergence.StandardError.ReadLineAsync(ct).ConfigureAwait(false) is { } line)
            {
                if (FramesLine().Match(line) is { Success: true } match && job.ExpectedFrames > 0)
                {
                    job.Progress = Math.Clamp(double.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture) / job.ExpectedFrames, 0, 0.999);
                }

                lastLines.Enqueue(line);
                if (lastLines.Count > 4)
                {
                    lastLines.Dequeue();
                }
            }
        }, ct);
        try
        {
            await vergence.WaitForExitAsync(ct).ConfigureAwait(false);
            await progress.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            Kill(vergence);
            throw;
        }

        if (vergence.ExitCode == 0)
        {
            return null;
        }

        var feederErrors = string.Join(" ", (await Task.WhenAll(errors).ConfigureAwait(false)).Select(e => e.Trim()).Where(e => e.Length > 0));
        return $"vergence exited {vergence.ExitCode}: {string.Join(" / ", lastLines)} {feederErrors}".Trim();
    }

    [GeneratedRegex(@"^vergence: (\d+) frames")]
    private static partial Regex FramesLine();

    private static async Task Pipe(Stream from, Stream to, CancellationToken ct)
    {
        try
        {
            await from.CopyToAsync(to, 1 << 20, ct).ConfigureAwait(false);
        }
        catch (IOException)
        {
            // The reader stopped (vergence failed, or the feeder ended early); FinishAsync says why.
        }
        finally
        {
            try
            {
                to.Close();
            }
            catch (IOException)
            {
            }
        }
    }

    /// <summary>A frame rate as ffmpeg's N/D, with the NTSC rates exact.</summary>
    internal static string Rational(double rate)
    {
        foreach (var (n, d) in new[] { (24000, 1001), (30000, 1001), (60000, 1001) })
        {
            if (Math.Abs(rate - ((double)n / d)) < 0.01)
            {
                return $"{n}/{d}";
            }
        }

        return string.Create(CultureInfo.InvariantCulture, $"{Math.Round(rate * 1000):0}/1000");
    }

    private Process Start(string fileName, IEnumerable<string> args, bool stdin)
    {
        var info = new ProcessStartInfo(fileName)
        {
            RedirectStandardInput = stdin,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        foreach (var arg in args)
        {
            info.ArgumentList.Add(arg);
        }

        var process = Process.Start(info) ?? throw new InvalidOperationException($"Could not start {fileName}");
        try
        {
            // Below playback's transcodes, which share the machine.
            process.PriorityClass = ProcessPriorityClass.BelowNormal;
        }
        catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
        }

        return process;
    }

    private static void Kill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill();
            }
        }
        catch (InvalidOperationException)
        {
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (IOException)
        {
        }
    }

    public void Dispose()
    {
        _lifetime.Cancel();
        _lifetime.Dispose();
        _worker.Dispose();
    }

    private sealed class Job
    {
        public volatile bool Started;
        public double ExpectedFrames;
        public double Progress;
    }
}

/// <summary>What <c>GET SmoothMotion/{itemId}</c> answers.</summary>
public sealed record SmoothMotionStatus(string State, string? Reason)
{
    public double? Progress { get; init; }
    public int? ChunkSeconds { get; init; }
    public int? Chunks { get; init; }
    public double? FrameRate { get; init; }
    public long? Bytes { get; init; }
}
