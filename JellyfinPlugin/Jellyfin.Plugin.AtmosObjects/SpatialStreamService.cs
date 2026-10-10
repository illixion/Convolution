using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Controller.Library;
using MediaBrowser.Model.Entities;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// Streams a spatial video (MV-HEVC, as a Vision Pro or iPhone records it) as
/// side-by-side HEVC over HLS, for players that can't decode its second view
/// (Quest, Android). Nothing is converted ahead of time and the whole video
/// is never stored: a request for a segment that isn't cached starts a run
/// of <c>vergence sbs --segments</c> (<see cref="RunSeconds"/> of video from
/// that segment), which writes each segment into the cache as soon as it is
/// complete. A seek elsewhere cancels the run and starts another there.
///
/// The segments are cut on a fixed grid (<see cref="PluginConfiguration.SpatialSegmentSeconds"/>
/// from the start), each opening with a keyframe and carrying the video's own
/// times, so any segment can be made on its own and segments from different
/// runs play as one stream. A run stops before a segment that is already
/// cached, so rewatching only converts what is missing.
///
///   &lt;cache&gt;/spatial/&lt;itemId&gt;/&lt;variant&gt;/info.json
///   &lt;cache&gt;/spatial/&lt;itemId&gt;/&lt;variant&gt;/init.mp4
///   &lt;cache&gt;/spatial/&lt;itemId&gt;/&lt;variant&gt;/&lt;n&gt;.m4s
///
/// The variant names the picture settings, so changing them never mixes
/// segments of two kinds. All items together keep at most
/// <see cref="PluginConfiguration.SpatialCacheMegabytes"/>; the least recently
/// served segments go first.
///
/// Decoding MV-HEVC needs Apple's frameworks, so this works on a Mac server
/// only; elsewhere every item reports <c>spatial: false</c> with the reason.
/// </summary>
public sealed partial class SpatialStreamService
{
    /// <summary>Video seconds one run converts before it stops; a later request starts the next.</summary>
    private const double RunSeconds = 120;
    /// <summary>How far ahead of a run's progress a request still waits for it instead of starting another.</summary>
    private const int FollowSeconds = 30;
    private static readonly TimeSpan SegmentWait = TimeSpan.FromSeconds(60);
    /// <summary>A run nobody has asked anything of for this long is stopped (a player buffers up to about a minute ahead).</summary>
    private static readonly TimeSpan IdleStop = TimeSpan.FromSeconds(120);
    /// <summary>Segments served this recently are never trimmed.</summary>
    private static readonly TimeSpan TrimGrace = TimeSpan.FromMinutes(2);
    private static readonly string[] Containers = [".mov", ".mp4", ".m4v", ".qt"];

    private readonly ILibraryManager _libraryManager;
    private readonly IMediaSourceManager _mediaSourceManager;
    private readonly IApplicationPaths _paths;
    private readonly ILogger<SpatialStreamService> _logger;
    private readonly ConcurrentDictionary<string, ItemState> _items = new();
    /// <summary>Every run on the server that hasn't finished, guarded by <see cref="_runsGate"/> (taken after an item's gate, never before).</summary>
    private readonly List<Run> _activeRuns = [];
    private readonly object _runsGate = new();
    private readonly object _trimGate = new();

    public SpatialStreamService(
        ILibraryManager libraryManager,
        IMediaSourceManager mediaSourceManager,
        IApplicationPaths paths,
        ILogger<SpatialStreamService> logger)
    {
        _libraryManager = libraryManager;
        _mediaSourceManager = mediaSourceManager;
        _paths = paths;
        _logger = logger;
    }

    private static PluginConfiguration Config => Plugin.Instance?.Configuration ?? new PluginConfiguration();

    private static double SegmentSeconds => Math.Clamp(Config.SpatialSegmentSeconds, 1, 10);

    private string Root => Path.Combine(
        string.IsNullOrWhiteSpace(Config.CacheDirectory) ? Path.Combine(_paths.CachePath, "atmos-objects") : Config.CacheDirectory,
        "spatial");

    /// <summary>The picture settings in force, as a folder name.</summary>
    private static string Variant => string.Create(CultureInfo.InvariantCulture,
        $"{SegmentSeconds:0.###}s-{(Config.SpatialHalfWidth ? "half" : "full")}-{Math.Max(0, Config.SpatialMaxEye)}-{Quality}");

    private static string Quality => Config.SpatialQuality?.ToLowerInvariant() is "low" or "high" or "max" ? Config.SpatialQuality.ToLowerInvariant() : "standard";

    // MARK: Client entry points

    /// <summary>The item's info (reading it with vergence once), or null for an unknown item.</summary>
    public async Task<SpatialInfo?> GetInfoAsync(Guid itemId, CancellationToken ct)
    {
        var state = GetState(itemId);
        if (state is null)
        {
            return null;
        }

        if (state.Info is { } known)
        {
            return known;
        }

        await state.InfoGate.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            return state.Info ??= await ReadInfoAsync(state, ct).ConfigureAwait(false);
        }
        finally
        {
            state.InfoGate.Release();
        }
    }

    /// <summary>
    /// The HLS media playlist for the whole video. Segment and init URIs are
    /// relative and carry <paramref name="query"/> (the request's own query
    /// string, with its api_key), so the player's follow-up requests are
    /// authorised the same way.
    /// </summary>
    public async Task<string?> GetPlaylistAsync(Guid itemId, string query, CancellationToken ct)
    {
        if (await GetInfoAsync(itemId, ct).ConfigureAwait(false) is not { Spatial: true } info || info.Segments <= 0)
        {
            return null;
        }

        return SpatialPlaylist.Build(info, query);
    }

    /// <summary>Path of the init segment, waiting for a run to write it (or starting one at the beginning).</summary>
    public async Task<string?> EnsureInitAsync(Guid itemId, CancellationToken ct)
    {
        if (await GetInfoAsync(itemId, ct).ConfigureAwait(false) is not { Spatial: true })
        {
            return null;
        }

        var state = GetState(itemId)!;
        var path = Path.Combine(state.Directory, "init.mp4");
        // A player asks for the init and its first segment together; give the
        // segment's run a moment to start before starting one at 0.
        var deadline = DateTime.UtcNow + SegmentWait;
        var grace = DateTime.UtcNow + TimeSpan.FromSeconds(2);
        while (DateTime.UtcNow < deadline)
        {
            if (File.Exists(path))
            {
                return path;
            }

            if (DateTime.UtcNow > grace)
            {
                lock (state.Gate)
                {
                    if (!state.Runs.Any(r => !r.Finished))
                    {
                        StartRun(state, 0);
                    }
                }
            }

            await Task.Delay(50, ct).ConfigureAwait(false);
        }

        return null;
    }

    /// <summary>Path of segment <paramref name="segment"/>, converting it if needed.</summary>
    public async Task<string?> EnsureSegmentAsync(Guid itemId, int segment, CancellationToken ct)
    {
        if (await GetInfoAsync(itemId, ct).ConfigureAwait(false) is not { Spatial: true } info
            || segment < 0 || segment >= info.Segments)
        {
            return null;
        }

        var state = GetState(itemId)!;
        state.LastRequest = DateTime.UtcNow;
        var path = SegmentPath(state, segment);
        var deadline = DateTime.UtcNow + SegmentWait;
        var started = 0;
        while (DateTime.UtcNow < deadline)
        {
            if (File.Exists(path))
            {
                File.SetLastAccessTimeUtc(path, DateTime.UtcNow);
                return path;
            }

            lock (state.Gate)
            {
                if (!state.Runs.Any(r => r.Covers(segment, FollowSegments(info))))
                {
                    // Two runs that both ended without making it: give up.
                    if (started++ >= 2)
                    {
                        return null;
                    }

                    StartRun(state, segment);
                }
            }

            await Task.Delay(50, ct).ConfigureAwait(false);
        }

        return null;
    }

    // MARK: State

    private sealed class ItemState
    {
        public readonly object Gate = new();
        public readonly SemaphoreSlim InfoGate = new(1, 1);
        public required Guid ItemId { get; init; }
        public required string MediaPath { get; init; }
        public required string Directory { get; init; }
        public SpatialInfo? Info;
        public readonly List<Run> Runs = [];
        public DateTime LastRequest = DateTime.UtcNow;
    }

    private sealed class Run
    {
        public required ItemState Item { get; init; }
        public required int FirstSegment { get; init; }
        public required int LastSegment { get; init; }
        /// <summary>The next segment the run will write.</summary>
        public volatile int NextSegment;
        public volatile bool Finished;
        public readonly CancellationTokenSource Cancellation = new();

        public SpatialRunProgress Progress => new(Finished, FirstSegment, LastSegment, NextSegment);

        public bool Covers(int segment, int follow) => Progress.Covers(segment, follow);
    }

    private static int FollowSegments(SpatialInfo info) => SpatialRunPlanner.FollowSegments(info.SegmentSeconds, FollowSeconds);

    private static string SegmentPath(ItemState state, int segment) => Path.Combine(state.Directory, $"{segment}.m4s");

    private ItemState? GetState(Guid itemId)
    {
        var key = itemId.ToString("N") + "/" + Variant;
        if (_items.TryGetValue(key, out var existing))
        {
            return existing;
        }

        var item = _libraryManager.GetItemById(itemId);
        if (item is null || string.IsNullOrEmpty(item.Path))
        {
            return null;
        }

        var directory = Path.Combine(Root, itemId.ToString("N"), Variant);
        var state = new ItemState { ItemId = itemId, MediaPath = item.Path, Directory = directory };
        // Temporary files of runs a stopped server left behind.
        if (System.IO.Directory.Exists(directory))
        {
            foreach (var stale in System.IO.Directory.GetFiles(directory, ".*"))
            {
                TryDelete(stale);
            }
        }

        return _items.GetOrAdd(key, state);
    }

    private async Task<SpatialInfo> ReadInfoAsync(ItemState state, CancellationToken ct)
    {
        var infoPath = Path.Combine(state.Directory, "info.json");
        var file = new FileInfo(state.MediaPath);
        if (!file.Exists)
        {
            return new SpatialInfo { Reason = "the file is missing" };
        }

        if (File.Exists(infoPath))
        {
            try
            {
                var cached = JsonSerializer.Deserialize<SpatialInfo>(await File.ReadAllTextAsync(infoPath, ct).ConfigureAwait(false), AtmosSceneService.JsonOptions);
                if (SpatialInfoCache.IsCurrent(cached, file.Length, file.LastWriteTimeUtc.Ticks))
                {
                    return cached;
                }
            }
            catch (JsonException)
            {
            }

            // The file changed: what was converted from it no longer applies.
            _logger.LogInformation("Spatial video {ItemId} changed on disk; clearing its segments", state.ItemId);
            foreach (var old in System.IO.Directory.GetFiles(state.Directory))
            {
                TryDelete(old);
            }
        }

        var (info, answered) = await ProbeAsync(state, ct).ConfigureAwait(false);
        info.SourceBytes = file.Length;
        info.SourceTicks = file.LastWriteTimeUtc.Ticks;
        // Not cached when vergence couldn't run or failed, so installing or updating it later works without a restart.
        if (SpatialInfoCache.ShouldStore(info, answered))
        {
            System.IO.Directory.CreateDirectory(state.Directory);
            var tmp = infoPath + ".tmp";
            await File.WriteAllTextAsync(tmp, JsonSerializer.Serialize(info, AtmosSceneService.JsonOptions), ct).ConfigureAwait(false);
            File.Move(tmp, infoPath, overwrite: true);
        }

        return info;
    }

    /// <summary>The item's info, and whether vergence read the file and answered.</summary>
    private async Task<(SpatialInfo Info, bool Answered)> ProbeAsync(ItemState state, CancellationToken ct)
    {
        // Only HEVC in a QuickTime-family container can be MV-HEVC spatial
        // video; anything else is answered without starting a process.
        if (!Containers.Contains(Path.GetExtension(state.MediaPath).ToLowerInvariant()))
        {
            return (new SpatialInfo { Reason = "not a QuickTime or MP4 file" }, false);
        }

        var video = _mediaSourceManager.GetMediaStreams(state.ItemId).FirstOrDefault(s => s.Type == MediaStreamType.Video);
        if (video?.Codec is { } codec && !string.Equals(codec, "hevc", StringComparison.OrdinalIgnoreCase))
        {
            return (new SpatialInfo { Reason = "not HEVC" }, false);
        }

        var vergence = AtmosSceneService.VergencePath(_paths);
        if (!File.Exists(vergence))
        {
            return (new SpatialInfo { Spatial = false, Reason = $"vergence not found at {vergence}; set Mvc3dPath in the plugin configuration" }, false);
        }

        var args = new List<string> { "sbs", state.MediaPath, "--info" };
        args.AddRange(PictureArguments());
        using var process = StartProcess(vergence, args);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(TimeSpan.FromSeconds(30));
        using var kill = timeout.Token.Register(() => TryKill(process));
        var stdout = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
        var stderr = process.StandardError.ReadToEndAsync(CancellationToken.None);
        await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        var output = await stdout.ConfigureAwait(false);
        if (process.ExitCode != 0)
        {
            var problem = (await stderr.ConfigureAwait(false)).Trim();
            _logger.LogWarning("vergence --info failed for {ItemId}: {Problem}", state.ItemId, problem);
            // Reported for the item, but not stored: an updated vergence gets another look.
            return (new SpatialInfo { Spatial = false, Reason = problem.Length > 0 ? problem : $"vergence exited {process.ExitCode}" }, false);
        }

        var info = JsonSerializer.Deserialize<SpatialInfo>(output, AtmosSceneService.JsonOptions) ?? new SpatialInfo();
        if (!info.Spatial)
        {
            info.Reason ??= "one view: not spatial video";
        }
        else
        {
            _logger.LogInformation("Spatial video {ItemId}: {Width}x{Height} side by side, {Segments} segments of {Seconds} s",
                state.ItemId, info.Width, info.Height, info.Segments, info.SegmentSeconds);
        }

        return (info, true);
    }

    private static IEnumerable<string> PictureArguments()
    {
        yield return "--segment-seconds";
        yield return SegmentSeconds.ToString("0.###", CultureInfo.InvariantCulture);
        yield return "--quality";
        yield return Quality;
        if (Config.SpatialHalfWidth)
        {
            yield return "--half";
        }

        if (Config.SpatialMaxEye > 0)
        {
            yield return "--max-eye";
            yield return Config.SpatialMaxEye.ToString(CultureInfo.InvariantCulture);
        }
    }

    // MARK: Runs

    /// <summary>Starts a run at <paramref name="segment"/>; the caller holds the item's gate.</summary>
    private void StartRun(ItemState state, int segment)
    {
        var info = state.Info!;
        // Up to RunSeconds, stopping before a segment that is already cached.
        var last = SpatialRunPlanner.LastSegment(segment, info.Segments, info.SegmentSeconds, RunSeconds, n => File.Exists(SegmentPath(state, n)));

        // A seek elsewhere (or far ahead) makes runs for the old position pointless.
        var follow = FollowSegments(info);
        foreach (var old in SpatialRunPlanner.Superseded(state.Runs, r => r.Progress, segment, follow))
        {
            old.Cancellation.Cancel();
        }

        var run = new Run { Item = state, FirstSegment = segment, LastSegment = last, NextSegment = segment };
        state.Runs.RemoveAll(r => r.Finished);
        state.Runs.Add(run);
        LimitRuns(run);
        _ = Task.Run(async () =>
        {
            try
            {
                await ExecuteRunAsync(state, run).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (run.Cancellation.IsCancellationRequested)
            {
                _logger.LogInformation("Spatial run for {ItemId} at segment {Segment} stopped at {Next}", state.ItemId, segment, run.NextSegment);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Spatial run for {ItemId} at segment {Segment} failed", state.ItemId, segment);
            }
            finally
            {
                run.Finished = true;
                lock (_runsGate)
                {
                    _activeRuns.Remove(run);
                }

                TrimCache();
            }
        });
    }

    /// <summary>
    /// Converting is a hardware decode and encode of two views at once, so
    /// only <see cref="PluginConfiguration.SpatialRuns"/> run on the server at
    /// a time: beyond that, the runs whose viewers asked least recently stop.
    /// Runs already stopping don't count, or a seek (which stops its item's
    /// old run first) would also stop another viewer's.
    /// </summary>
    private void LimitRuns(Run started)
    {
        lock (_runsGate)
        {
            var active = _activeRuns.Where(r => !r.Finished && !r.Cancellation.IsCancellationRequested);
            foreach (var run in SpatialRunPlanner.OverLimit(active, r => r.Item.LastRequest, Config.SpatialRuns))
            {
                _logger.LogInformation("Stopping the spatial run for {ItemId} to make room", run.Item.ItemId);
                run.Cancellation.Cancel();
            }

            _activeRuns.Add(started);
        }
    }

    [GeneratedRegex(@"^vergence: segment (\d+)$")]
    private static partial Regex SegmentLine();

    private async Task ExecuteRunAsync(ItemState state, Run run)
    {
        var ct = run.Cancellation.Token;
        System.IO.Directory.CreateDirectory(state.Directory);
        var args = new List<string>
        {
            "sbs", state.MediaPath, "--segments", state.Directory,
            "--first", run.FirstSegment.ToString(CultureInfo.InvariantCulture),
            "--last", run.LastSegment.ToString(CultureInfo.InvariantCulture)
        };
        args.AddRange(PictureArguments());
        _logger.LogInformation("Spatial run for {ItemId}: segments {First}-{Last}", state.ItemId, run.FirstSegment, run.LastSegment);
        var began = Stopwatch.StartNew();
        using var process = StartProcess(AtmosSceneService.VergencePath(_paths), args);
        using var kill = ct.Register(() => TryKill(process));
        _ = process.StandardOutput.ReadToEndAsync(CancellationToken.None);
        var problems = new StringBuilder();
        var lines = Task.Run(async () =>
        {
            while (await process.StandardError.ReadLineAsync(CancellationToken.None).ConfigureAwait(false) is { } line)
            {
                if (SegmentLine().Match(line) is { Success: true } match)
                {
                    run.NextSegment = int.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture) + 1;
                }
                else if (problems.Length < 4000)
                {
                    problems.AppendLine(line);
                }
            }
        }, CancellationToken.None);

        // Stop when nobody is watching any more.
        while (!process.HasExited)
        {
            if (DateTime.UtcNow - state.LastRequest > IdleStop)
            {
                _logger.LogInformation("Spatial run for {ItemId}: nobody asked for {Idle}; stopping", state.ItemId, IdleStop);
                run.Cancellation.Cancel();
            }

            try
            {
                await process.WaitForExitAsync(ct).WaitAsync(TimeSpan.FromSeconds(5), ct).ConfigureAwait(false);
            }
            catch (TimeoutException)
            {
            }
        }

        await Task.WhenAny(lines, Task.Delay(TimeSpan.FromSeconds(2), CancellationToken.None)).ConfigureAwait(false);
        ct.ThrowIfCancellationRequested();
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"vergence exited {process.ExitCode}: {problems.ToString().Trim()}");
        }

        _logger.LogInformation("Spatial run for {ItemId}: segments {First}-{Last} in {Seconds:F1} s",
            state.ItemId, run.FirstSegment, run.LastSegment, began.Elapsed.TotalSeconds);
    }

    /// <summary>Drops the least recently served segments beyond the budget, across every item.</summary>
    private void TrimCache()
    {
        lock (_trimGate)
        {
            if (!System.IO.Directory.Exists(Root))
            {
                return;
            }

            var budget = SpatialCacheTrimmer.BudgetBytes(Config.SpatialCacheMegabytes);
            var files = new DirectoryInfo(Root).EnumerateFiles("*.m4s", SearchOption.AllDirectories)
                .Select(f => new SpatialCacheFile(f.FullName, f.Length, f.LastAccessTimeUtc, f.LastWriteTimeUtc));
            var drop = SpatialCacheTrimmer.ToDelete(files, budget, DateTime.UtcNow, TrimGrace);
            foreach (var file in drop)
            {
                TryDelete(file.Path);
            }

            if (drop.Count > 0)
            {
                _logger.LogInformation("Spatial cache: dropped {Count} segments over {Megabytes} MB", drop.Count, budget / (1024 * 1024));
            }
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
        catch (UnauthorizedAccessException)
        {
        }
    }

    private static void TryKill(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException)
        {
        }
    }

    private static Process StartProcess(string fileName, IEnumerable<string> args)
    {
        var info = new ProcessStartInfo(fileName)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        foreach (var arg in args)
        {
            info.ArgumentList.Add(arg);
        }

        return Process.Start(info) ?? throw new InvalidOperationException($"Could not start {fileName}");
    }
}
