using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Controller.Entities;
using MediaBrowser.Controller.Library;
using MediaBrowser.Controller.MediaEncoding;
using MediaBrowser.Model.Entities;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.AtmosObjects;

public enum SceneState
{
    /// <summary>Nothing decoded yet.</summary>
    None,
    /// <summary>Some segments are cached; the rest decode on request.</summary>
    Partial,
    /// <summary>A decode is running through to the end of the film.</summary>
    Preparing,
    /// <summary>Every segment is cached.</summary>
    Ready,
    Unsupported,
    Failed
}

public sealed record SceneStatus(SceneState State, double ProgressSeconds, double DurationSeconds, string? Error);

/// <summary>Which decoder an item's Atmos track goes through.</summary>
public enum AudioCodecKind
{
    /// <summary>truehdd, an external subprocess (see <see cref="AtmosSceneService"/>'s main doc comment).</summary>
    TrueHd,
    /// <summary>Cavern.Format, in-process (see <c>Eac3AtmosDecoder.cs</c>).</summary>
    Eac3,
    /// <summary>
    /// DTS:X on DTS-HD MA, through harletty (a truehdd fork that also decodes
    /// DTS:X into the same DAMF master set; an external subprocess like
    /// truehdd). Offered only to a client that lists <c>dtsx</c> in
    /// <c>objectCodecs</c>.
    /// </summary>
    Dtsx
}

/// <summary>
/// Decodes an item's Atmos objects on demand, from any point in the film.
///
/// A request for a segment that is not cached starts a live session at that
/// segment: jellyfin-ffmpeg seeks and copies the TrueHD track out as Matroska
/// (so each packet keeps its timestamp), the packets from the first restart
/// point on are fed to truehdd, and truehdd streams the decoded object audio
/// back on stdout (the <c>--audio-stdout</c> patch in <c>truehdd/</c>). The
/// packet timestamps pin the first decoded sample to an exact scene frame
/// (<see cref="StartSolver"/>), so audio from any session lands on one fixed
/// grid of segments:
///
///   &lt;cache&gt;/v2/&lt;itemId&gt;/scene.json              layout (written by the first session)
///   &lt;cache&gt;/v2/&lt;itemId&gt;/seg/&lt;n&gt;.events.json       snapshot + events for segment n
///   &lt;cache&gt;/v2/&lt;itemId&gt;/seg/&lt;n&gt;-&lt;g&gt;.flac          16-bit FLAC, channel group g
///
/// A segment is complete once its last group's FLAC exists (each file is
/// renamed into place). A session keeps decoding ahead of the viewer and stops
/// at the end of the film, on reaching segments already cached, or when nobody
/// has asked for the item in a while. Prepare runs one session from the start
/// to the end, filling the whole cache.
/// </summary>
public sealed partial class AtmosSceneService
{
    private const int MaxChannelsPerGroup = 8;
    private const int SampleRate = 48000;
    private const int SamplesPerAu = 40;
    /// <summary>
    /// Decode starts this far before the requested segment so it is complete.
    /// It must also cover finding the start sample: on remuxes whose timestamps
    /// drift (see <see cref="StartSolver"/>) that can take a few restarts,
    /// measured up to 3.8 s of packets on The Wild Robot.
    /// </summary>
    private const double PrerollSeconds = 6;
    /// <summary>How far ahead of a running session a request still waits for it instead of restarting.</summary>
    private const int FollowSegments = 6;
    private static readonly TimeSpan IdleStop = TimeSpan.FromMinutes(10);
    private static readonly TimeSpan SegmentWait = TimeSpan.FromSeconds(45);

    public static readonly JsonSerializerOptions JsonOptions = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };

    private readonly ILibraryManager _libraryManager;
    private readonly IMediaSourceManager _mediaSourceManager;
    private readonly IMediaEncoder _mediaEncoder;
    private readonly IApplicationPaths _paths;
    private readonly ILogger<AtmosSceneService> _logger;
    private readonly ConcurrentDictionary<Guid, ItemState> _items = new();

    public AtmosSceneService(
        ILibraryManager libraryManager,
        IMediaSourceManager mediaSourceManager,
        IMediaEncoder mediaEncoder,
        IApplicationPaths paths,
        ILogger<AtmosSceneService> logger)
    {
        _libraryManager = libraryManager;
        _mediaSourceManager = mediaSourceManager;
        _mediaEncoder = mediaEncoder;
        _paths = paths;
        _logger = logger;
    }

    private static PluginConfiguration Config => Plugin.Instance?.Configuration ?? new PluginConfiguration();

    private static int SegmentFrames => SampleRate * Math.Max(1, Config.SegmentSeconds);

    private string CacheRoot => Path.Combine(
        string.IsNullOrWhiteSpace(Config.CacheDirectory) ? Path.Combine(_paths.CachePath, "atmos-objects") : Config.CacheDirectory,
        "v2");

    private string TruehddPath => string.IsNullOrWhiteSpace(Config.TruehddPath)
        ? Path.Combine(Plugin.Instance?.DataFolderPath ?? _paths.PluginConfigurationsPath, "truehdd")
        : Config.TruehddPath;

    private string HarlettyPath => string.IsNullOrWhiteSpace(Config.HarlettyPath)
        ? Path.Combine(Plugin.Instance?.DataFolderPath ?? _paths.PluginConfigurationsPath, "harletty")
        : Config.HarlettyPath;

    /// <summary>
    /// A decoder that writes a DAMF master set (truehdd for TrueHD, harletty
    /// for DTS:X), and how the packets ffmpeg copies out are cut for it.
    /// </summary>
    /// <param name="Arguments">Everything but the output path, which follows them.</param>
    /// <param name="StartsAt">Whether a packet can open the stream the decoder is fed.</param>
    /// <param name="Units">Access units in a packet.</param>
    /// <param name="SamplesPerUnit">Samples in an access unit, from the first packet fed.</param>
    /// <param name="MinimumRun">Packets held back until the cut is proven continuous.</param>
    /// <param name="PinBeds">Bed channels other than the LFE become objects at their speakers (a DTS:X bed is a real 7.1).</param>
    /// <param name="ToleranceMs">How far a packet's timestamp may stray (<see cref="StartSolver"/>).</param>
    private sealed record DamfTool(string Name, string Path, string[] Arguments, Func<byte[], bool> StartsAt,
        Func<byte[], int> Units, Func<byte[], int> SamplesPerUnit, int MinimumRun, bool PinBeds, string Format,
        double ToleranceMs = 0.5);

    private DamfTool ToolFor(AudioCodecKind codec) => codec == AudioCodecKind.Dtsx
        ? new DamfTool("harletty", HarlettyPath,
            ["--loglevel", "error", "--codec", "dts", "decode", "-", "--audio-stdout", "--bed-conform", "--output-path"],
            p => DtsFrames.StartsAtFrame(p), p => DtsFrames.Count(p), p => DtsFrames.SamplesPerFrame(p),
            64, PinBeds: true, Format: "DTS:X", ToleranceMs: 1.5)
        : new DamfTool("truehdd", TruehddPath, ["--loglevel", "error", "decode", "-", "--audio-stdout", "--output-path"],
            OpensWithMajorSync, CountAccessUnits, _ => SamplesPerAu, 3 * 128, PinBeds: false, Format: "TrueHD");

    // The Vergence CLI, installed as "vergence"; servers set up before the
    // rename still have it as "mvc3d".
    private string Mvc3dPath => VergencePath(_paths);

    internal static string VergencePath(IApplicationPaths paths)
    {
        if (!string.IsNullOrWhiteSpace(Config.Mvc3dPath))
        {
            return Config.Mvc3dPath;
        }

        var folder = Plugin.Instance?.DataFolderPath ?? paths.PluginConfigurationsPath;
        var vergence = Path.Combine(folder, "vergence");
        return File.Exists(vergence) ? vergence : Path.Combine(folder, "mvc3d");
    }

    private string ItemDirectory(Guid itemId) => Path.Combine(CacheRoot, itemId.ToString("N"));

    public string ScenePath(Guid itemId) => Path.Combine(ItemDirectory(itemId), "scene.json");

    private string FlacPath(Guid itemId, int segment, int group) => Path.Combine(ItemDirectory(itemId), "seg", $"{segment}-{group}.flac");

    private string EventsPath(Guid itemId, int segment) => Path.Combine(ItemDirectory(itemId), "seg", $"{segment}.events.json");

    private string CompletePath(Guid itemId) => Path.Combine(ItemDirectory(itemId), "complete");

    /// <summary>
    /// The cached "no Atmos here" verdict. The name carries the set of decoders
    /// that reached it, so a plugin that learns a new format retries instead of
    /// trusting an older verdict: <c>unsupported.txt</c> was written when only
    /// TrueHD was decoded, and marked every EAC3-only film unsupported.
    /// <c>unsupported-truehd-eac3.txt</c> came before DTS:X, and before tracks
    /// were mapped to the file's own stream index: a film with a sidecar
    /// subtitle had its decoder fed the wrong stream, which could read as no
    /// objects.
    /// </summary>
    private string UnsupportedPath(Guid itemId) => Path.Combine(ItemDirectory(itemId), "unsupported-truehd-eac3-dtsx.txt");

    // MARK: Client entry points

    public SceneStatus GetStatus(Guid itemId)
    {
        var state = _items.GetValueOrDefault(itemId);
        var duration = state?.Source?.DurationSeconds ?? 0;
        if (File.Exists(CompletePath(itemId)))
        {
            return new SceneStatus(SceneState.Ready, duration, duration, null);
        }

        if (File.Exists(UnsupportedPath(itemId)))
        {
            return new SceneStatus(SceneState.Unsupported, 0, 0, File.ReadAllText(UnsupportedPath(itemId)));
        }

        var session = state?.Session;
        if (session is { Finished: false, ToEnd: true })
        {
            return new SceneStatus(SceneState.Preparing, session.NextSegment * (double)Config.SegmentSeconds, duration, null);
        }

        if (state?.Error is { } error)
        {
            return new SceneStatus(SceneState.Failed, 0, duration, error);
        }

        return new SceneStatus(File.Exists(ScenePath(itemId)) ? SceneState.Partial : SceneState.None, 0, duration, null);
    }

    /// <summary>Decodes the whole film into the cache in the background. False for unknown items.</summary>
    public bool Prepare(Guid itemId)
    {
        var state = GetState(itemId);
        if (state is null)
        {
            return false;
        }

        if (!File.Exists(CompletePath(itemId)) && !File.Exists(UnsupportedPath(itemId)))
        {
            EnsureSession(itemId, state, 0, toEnd: true);
        }

        return true;
    }

    /// <summary>
    /// The scene layout, starting a session at <paramref name="startSeconds"/>
    /// if no decode has produced one yet. Null when the item has no Atmos track.
    /// </summary>
    public async Task<SceneDocument?> GetSceneAsync(Guid itemId, double startSeconds, CancellationToken ct)
    {
        var state = GetState(itemId) ?? throw new FileNotFoundException("Unknown item.");
        state.LastRequest = DateTime.UtcNow;
        var deadline = DateTime.UtcNow + SegmentWait;
        while (DateTime.UtcNow < deadline)
        {
            if (ReadLayout(itemId, state) is { } layout)
            {
                // Start decoding where playback will begin while the client sets up.
                var first = (int)(Math.Max(0, startSeconds) / Config.SegmentSeconds);
                if (first < layout.SegmentCount && !IsComplete(itemId, first, layout.Groups.Count))
                {
                    EnsureSession(itemId, state, first, toEnd: false);
                }

                return layout;
            }

            if (File.Exists(UnsupportedPath(itemId)))
            {
                return null;
            }

            if (state.Error is { } error && state.Session is null or { Finished: true })
            {
                throw new InvalidOperationException(error);
            }

            EnsureSession(itemId, state, (int)(Math.Max(0, startSeconds) / Config.SegmentSeconds), toEnd: false);
            await Task.Delay(100, ct).ConfigureAwait(false);
        }

        throw new TimeoutException("The decoder did not produce a scene layout in time.");
    }

    /// <summary>Waits until segment <paramref name="segment"/> is cached, decoding it if needed.</summary>
    public async Task<bool> EnsureSegmentAsync(Guid itemId, int segment, CancellationToken ct)
    {
        var state = GetState(itemId);
        if (state is null || ReadLayout(itemId, state) is not { } layout || segment < 0 || segment >= layout.SegmentCount)
        {
            return false;
        }

        state.LastRequest = DateTime.UtcNow;
        var deadline = DateTime.UtcNow + SegmentWait;
        while (DateTime.UtcNow < deadline)
        {
            if (IsComplete(itemId, segment, layout.Groups.Count))
            {
                return true;
            }

            EnsureSession(itemId, state, segment, toEnd: false);
            await Task.Delay(50, ct).ConfigureAwait(false);
        }

        return false;
    }

    public string? SegmentFlac(Guid itemId, int segment, int group)
    {
        var path = FlacPath(itemId, segment, group);
        return File.Exists(path) ? path : null;
    }

    public string? SegmentEvents(Guid itemId, int segment)
    {
        var path = EventsPath(itemId, segment);
        return File.Exists(path) ? path : null;
    }

    // MARK: Item state

    /// <param name="StreamIndex">The track's index in the file, as ffmpeg numbers it (not Jellyfin's).</param>
    /// <param name="DurationSeconds">Jellyfin's run time: a length, from the file's start time.</param>
    /// <param name="OriginMs">The track's first timestamp, on the file's own clock: scene frame 0.</param>
    /// <param name="StartMs">The file's start time on that clock (Jellyfin's position 0): 0 for
    /// Matroska, the first timestamp for a transport stream (near 600 s for a Blu-ray M2TS).</param>
    /// <param name="IsDisc">A Blu-ray ISO or BDMV folder, read through <see cref="DiscFeed"/>.</param>
    private sealed record ItemSource(string Path, int StreamIndex, double DurationSeconds, double OriginMs, double StartMs, AudioCodecKind Codec, bool IsDisc = false)
    {
        /// <summary>The track's length from its origin to the end of the file.</summary>
        public double TrackSeconds => DurationSeconds - ((OriginMs - StartMs) / 1000);
    }

    /// <summary>A Blu-ray disc image or folder: ffmpeg can only read it through <c>bluray:</c>, which can't seek in usable time.</summary>
    private static bool IsBluray(BaseItem item) => item is Video
    {
        VideoType: VideoType.BluRay
    } or Video { VideoType: VideoType.Iso, IsoType: IsoType.BluRay };

    private sealed class ItemState
    {
        public readonly object Gate = new();
        public ItemSource? Source;
        public LiveSession? Session;
        public SceneDocument? Layout;
        public string? Error;
        public DateTime LastRequest = DateTime.UtcNow;
    }

    private sealed class LiveSession
    {
        public required int FirstSegment { get; init; }
        public volatile bool ToEnd;
        public volatile int NextSegment;
        public volatile bool Finished;
        public readonly CancellationTokenSource Cancellation = new();

        public bool Covers(int segment) => !Finished && segment >= FirstSegment && segment <= NextSegment + FollowSegments;
    }

    /// <summary>A scene's state; <paramref name="itemId"/> is a scene id from <see cref="ResolveScene"/>.</summary>
    private ItemState? GetState(Guid itemId)
    {
        if (_items.TryGetValue(itemId, out var existing))
        {
            return existing;
        }

        if (!_sceneTargets.TryGetValue(itemId, out var target))
        {
            return null;
        }

        var item = _libraryManager.GetItemById(target.Item);
        if (item is null || string.IsNullOrEmpty(item.Path))
        {
            return null;
        }

        var state = new ItemState();
        // No session can be running for a scene not yet in _items: any work
        // folder here was left by a server stopped mid-decode.
        DeleteStale(ItemDirectory(itemId), "work-*");
        var disc = IsBluray(item);
        var candidate = Candidates(target.Item)?.FirstOrDefault(c => c.Index == target.Stream);
        if (candidate is null)
        {
            MarkUnsupported(itemId, disc ? "No TrueHD audio track on the disc." : "No TrueHD or EAC3 audio track.");
        }
        else
        {
            var (originMs, startMs) = ProbeOrigin(item.Path, candidate.FileIndex, disc);
            state.Source = new ItemSource(
                item.Path,
                candidate.FileIndex,
                item.RunTimeTicks is long ticks ? TimeSpan.FromTicks(ticks).TotalSeconds : 0,
                originMs,
                startMs,
                candidate.Codec,
                disc);
        }

        return _items.GetOrAdd(itemId, state);
    }

    private SceneDocument? ReadLayout(Guid itemId, ItemState state)
    {
        if (state.Layout is null && File.Exists(ScenePath(itemId)))
        {
            var cached = JsonSerializer.Deserialize<SceneDocument>(File.ReadAllText(ScenePath(itemId)), JsonOptions);
            // An estimate written before the length counted from the file's
            // start time: negative for a stream whose clock starts late (a
            // Blu-ray M2TS). Estimated again from the source.
            state.Layout = cached is { FrameCount: > 0 } ? cached : null;
        }

        return state.Layout;
    }

    private bool IsComplete(Guid itemId, int segment, int groups) => File.Exists(FlacPath(itemId, segment, groups - 1));

    private void EnsureSession(Guid itemId, ItemState state, int segment, bool toEnd)
    {
        if (state.Source is not { } source || File.Exists(UnsupportedPath(itemId)))
        {
            return;
        }

        lock (state.Gate)
        {
            if (state.Session is { } running && running.Covers(segment))
            {
                running.ToEnd |= toEnd;
                return;
            }

            state.Session?.Cancellation.Cancel();
            var session = new LiveSession { FirstSegment = segment, ToEnd = toEnd, NextSegment = segment };
            state.Session = session;
            state.Error = null;
            _ = Task.Run(async () =>
            {
                try
                {
                    await RunSessionAsync(itemId, state, source, session).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (session.Cancellation.IsCancellationRequested)
                {
                    _logger.LogInformation("Atmos session for {ItemId} at segment {Segment} cancelled at {Next}", itemId, segment, session.NextSegment);
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Atmos session for {ItemId} at segment {Segment} failed", itemId, segment);
                    state.Error = ex.Message;
                }
                finally
                {
                    session.Finished = true;
                }
            });
        }
    }

    // MARK: Live session

    /// <summary>Dispatches to the decoder matching the item's Atmos track.</summary>
    private Task RunSessionAsync(Guid itemId, ItemState state, ItemSource source, LiveSession session) =>
        source.Codec == AudioCodecKind.Eac3
            ? RunEac3SessionAsync(itemId, state, source, session)
            : RunDamfSessionAsync(itemId, state, source, session, ToolFor(source.Codec));

    private async Task RunDamfSessionAsync(Guid itemId, ItemState state, ItemSource source, LiveSession session, DamfTool tool)
    {
        var ct = session.Cancellation.Token;
        if (!File.Exists(tool.Path))
        {
            throw new FileNotFoundException($"{tool.Name} not found at {tool.Path}; set {(tool.Name == "harletty" ? "HarlettyPath" : "TruehddPath")} in the plugin configuration.");
        }

        var segmentFrames = SegmentFrames;
        var atStreamStart = session.FirstSegment == 0;
        var seekSeconds = (source.OriginMs / 1000) + (session.FirstSegment * (double)Config.SegmentSeconds) - PrerollSeconds;
        var dir = ItemDirectory(itemId);
        var work = Path.Combine(dir, "work-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(Path.Combine(dir, "seg"));
        Directory.CreateDirectory(work);
        var basePath = Path.Combine(work, "out");
        _logger.LogInformation("Atmos session for {ItemId}: segment {Segment}, seek {Seek:F1} s, to end {ToEnd}", itemId, session.FirstSegment, seekSeconds, session.ToEnd);

        var ffmpegArgs = new List<string> { "-v", "error", "-nostdin" };
        // A disc is cut by Vergence, in playlist time, which starts at the origin.
        using var feed = source.IsDisc ? DiscFeed.Start(Mvc3dPath, source.Path, atStreamStart ? 0 : seekSeconds - (source.OriginMs / 1000)) : null;
        if (!atStreamStart && feed is null)
        {
            // seekSeconds is on the file's own clock (origin included).
            // Without -seek_timestamp, ffmpeg adds the file's start time to
            // -ss, which is 0 for Matroska but not for a transport stream
            // (a Blu-ray M2TS's clock starts near 600 s, and the cut landed
            // past the end).
            ffmpegArgs.AddRange(["-seek_timestamp", "1", "-ss", seekSeconds.ToString("F3", CultureInfo.InvariantCulture)]);
        }

        ffmpegArgs.AddRange(["-i", feed is null ? source.Path : "pipe:0", "-map", $"0:{source.StreamIndex}", "-c", "copy", "-copyts", "-f", "matroska", "pipe:1"]);
        using var ffmpeg = StartProcess(_mediaEncoder.EncoderPath, ffmpegArgs, redirectInput: feed is not null);
        feed?.Connect(ffmpeg);
        using var truehdd = StartProcess(tool.Path, [.. tool.Arguments, basePath], redirectInput: true);
        using var kill = ct.Register(() =>
        {
            feed?.Dispose();
            TryKill(ffmpeg);
            TryKill(truehdd);
        });
        var ffmpegErr = ffmpeg.StandardError.ReadToEndAsync(CancellationToken.None);
        var truehddErr = truehdd.StandardError.ReadToEndAsync(CancellationToken.None);

        var start = new TaskCompletionSource<long>(TaskCreationOptions.RunContinuationsAsynchronously);
        var feeder = Task.Run(() => FeedAsync(ffmpeg, truehdd, source.OriginMs, start, tool, ct), ct);
        _ = start.Task.ContinueWith(
            t => _logger.LogInformation("Atmos session for {ItemId}: cut starts at frame {Frame} ({Seconds:F3} s)", itemId, t.Result, t.Result / (double)SampleRate),
            TaskContinuationOptions.OnlyOnRanToCompletion);

        try
        {
            var outcome = await ReadAudioAsync(itemId, state, source, session, truehdd, basePath, start.Task, atStreamStart, segmentFrames, tool, ct).ConfigureAwait(false);
            _logger.LogInformation("Atmos session for {ItemId}: {Outcome} at segment {Segment}", itemId, outcome, session.NextSegment);

            // truehdd's output has ended (or we stopped reading): nothing will
            // drain ffmpeg any more, so stop it rather than leave the feeder
            // blocked on a full pipe.
            await truehdd.WaitForExitAsync(ct).ConfigureAwait(false);
            if (outcome != AudioOutcome.Stopped)
            {
                TryKill(ffmpeg);
                await Task.WhenAny(feeder, Task.Delay(TimeSpan.FromSeconds(5), CancellationToken.None)).ConfigureAwait(false);
            }

            if (truehdd.ExitCode != 0 && outcome != AudioOutcome.Stopped)
            {
                throw new InvalidOperationException($"{tool.Name} exited {truehdd.ExitCode}: {(await truehddErr.ConfigureAwait(false)).Trim()}");
            }

            if (outcome == AudioOutcome.NoObjects && feeder.IsCompleted)
            {
                // A feeder failure also ends truehdd's input early; it is an error, not a verdict.
                await feeder.ConfigureAwait(false);
            }

            if (outcome == AudioOutcome.NoObjects)
            {
                // Only a clean decode of the whole remaining stream says the track has no objects.
                MarkUnsupported(itemId, $"The {tool.Format} track has no object presentation.");
                return;
            }

            if (outcome == AudioOutcome.Finished)
            {
                await feeder.ConfigureAwait(false);
            }
        }
        catch (NoObjectsException) when (!ct.IsCancellationRequested)
        {
            TryKill(ffmpeg);
            TryKill(truehdd);
            MarkUnsupported(itemId, $"The {tool.Format} track has no object presentation.");
            return;
        }
        catch (Exception) when (!ct.IsCancellationRequested)
        {
            TryKill(ffmpeg);
            TryKill(truehdd);
            var feedErrors = feed is null ? string.Empty : await feed.ErrorsAsync().ConfigureAwait(false);
            var errors = $"{feedErrors} {(await ffmpegErr.ConfigureAwait(false)).Trim()} {(await truehddErr.ConfigureAwait(false)).Trim()}".Trim();
            if (errors.Length > 0)
            {
                _logger.LogWarning("Atmos session tool output: {Errors}", errors);
            }

            if (feeder.IsFaulted)
            {
                _logger.LogWarning(feeder.Exception, "Atmos session feeder failed");
            }

            throw;
        }
        finally
        {
            TryKill(ffmpeg);
            TryKill(truehdd);
            try
            {
                Directory.Delete(work, recursive: true);
            }
            catch (IOException)
            {
            }
        }
    }

    /// <summary>
    /// Copies Matroska packets into truehdd, starting at an access unit that
    /// opens with a major sync (a restart point), and solves that unit's scene
    /// frame from the packet timestamps.
    ///
    /// Packets are held back until the run is proven continuous: right after a
    /// seek, the Matroska demuxer hands over the restart-point packet and then
    /// jumps a whole restart interval (128 access units) ahead, so the first
    /// packet is not followed by its own successors. Any timestamp gap drops the
    /// run and starts again at the next restart point.
    /// </summary>
    private static async Task FeedAsync(Process ffmpeg, Process truehdd, double originMs, TaskCompletionSource<long> start,
        DamfTool tool, CancellationToken ct)
    {
        var minimumRun = tool.MinimumRun;
        var samplesPerUnit = SamplesPerAu;
        var packets = new MatroskaPackets(ffmpeg.StandardOutput.BaseStream);
        var input = truehdd.StandardInput.BaseStream;
        var run = new List<byte[]>();
        StartSolver? solver = null;
        double runStartMs = 0;
        long runSamples = 0;
        var dropped = 0;
        try
        {
            while (await packets.ReadAsync(ct).ConfigureAwait(false) is var (time, data))
            {
                if (start.Task.IsCompleted)
                {
                    await input.WriteAsync(data, ct).ConfigureAwait(false);
                    continue;
                }

                var expected = runStartMs + (runSamples * 1000.0 / SampleRate);
                if (solver is not null && Math.Abs(time - expected) > 0.5 + (2 * tool.ToleranceMs))
                {
                    // Discontinuity: this run cannot be decoded as one stream.
                    solver = null;
                    run.Clear();
                    if (++dropped > 50)
                    {
                        throw new InvalidDataException($"No continuous run of {tool.Format} packets after the seek point.");
                    }
                }

                if (solver is null)
                {
                    if (!tool.StartsAt(data))
                    {
                        continue;
                    }

                    samplesPerUnit = tool.SamplesPerUnit(data);
                    solver = new StartSolver(SampleRate, samplesPerUnit, originMs, tool.ToleranceMs);
                    runStartMs = time;
                    runSamples = 0;
                }

                var units = tool.Units(data);
                solver.Add(time, units);
                if (!solver.IsConsistent)
                {
                    // The timestamps drifted off the sample grid mid-run (see
                    // StartSolver): start over at the next restart point.
                    solver = null;
                    run.Clear();
                    if (++dropped > 50)
                    {
                        throw new InvalidDataException("Packet timestamps are inconsistent with a fixed access-unit length.");
                    }

                    continue;
                }

                runSamples += (long)units * samplesPerUnit;
                run.Add(data);
                if (run.Count >= minimumRun && solver.Solve() is long frame)
                {
                    foreach (var held in run)
                    {
                        await input.WriteAsync(held, ct).ConfigureAwait(false);
                    }

                    run.Clear();
                    start.TrySetResult(frame);
                }
                else if (run.Count > 20000)
                {
                    throw new InvalidDataException("Could not pin the cut to a sample from packet timestamps.");
                }
            }

            if (!start.Task.IsCompleted)
            {
                throw new InvalidDataException("The stream ended before its start sample could be determined.");
            }
        }
        catch (Exception ex)
        {
            start.TrySetException(ex);
            throw;
        }
        finally
        {
            try
            {
                input.Close();
            }
            catch (IOException)
            {
            }
        }
    }

    private static bool OpensWithMajorSync(byte[] au) =>
        au.Length >= 8 && au[4] == 0xF8 && au[5] == 0x72 && au[6] == 0x6F && au[7] == 0xBA;

    private static int CountAccessUnits(byte[] data)
    {
        int count = 0, p = 0;
        while (p + 2 <= data.Length)
        {
            var length = (((data[p] << 8) | data[p + 1]) & 0xFFF) * 2;
            if (length == 0)
            {
                break;
            }

            p += length;
            count++;
        }

        return Math.Max(count, 1);
    }

    /// <summary>The decoder produced plenty of audio but never an object header.</summary>
    private sealed class NoObjectsException : Exception
    {
    }

    private enum AudioOutcome
    {
        /// <summary>truehdd's output ended after audio was placed.</summary>
        Finished,
        /// <summary>The session decided to stop (cached region reached, or idle).</summary>
        Stopped,
        /// <summary>truehdd's output ended without ever writing a DAMF header.</summary>
        NoObjects
    }

    /// <summary>
    /// Reads truehdd's PCM, places it on the scene-frame grid, and completes
    /// segments as they fill. Output is held until both the start frame and the
    /// DAMF header (which names the channels) are known.
    /// </summary>
    private async Task<AudioOutcome> ReadAudioAsync(
        Guid itemId, ItemState state, ItemSource source, LiveSession session, Process truehdd, string basePath,
        Task<long> startTask, bool atStreamStart, int segmentFrames, DamfTool tool, CancellationToken ct)
    {
        var stdout = truehdd.StandardOutput.BaseStream;
        var pending = new MemoryStream();
        var chunk = new byte[1 << 16];
        using var encoders = new SemaphoreSlim(Math.Max(1, Config.EncoderParallelism));
        var encoding = new List<Task>();

        Grid? grid = null;
        while (true)
        {
            var read = await stdout.ReadAsync(chunk, ct).ConfigureAwait(false);
            if (grid is null)
            {
                if (read > 0)
                {
                    pending.Write(chunk, 0, read);
                }

                if (startTask.IsCompleted && File.Exists(basePath + ".atmos"))
                {
                    var startFrame = await startTask.ConfigureAwait(false);
                    var (elements, pinned) = DamfReader.ReadElements(basePath + ".atmos", tool.PinBeds);
                    var layout = WriteLayoutIfMissing(itemId, state, source, elements);
                    ISceneEventSource events = new DamfEventSource(new DamfEventStream(startFrame), basePath + ".atmos.metadata");
                    if (pinned.Count > 0)
                    {
                        events = new PinnedBedEvents(events, pinned);
                    }
                    grid = new Grid(this, itemId, state, session, layout, events, startFrame, atStreamStart, segmentFrames, encoders, encoding);
                    grid.Append(pending.GetBuffer().AsSpan(0, (int)pending.Length));
                    pending = new MemoryStream();
                }
                else if (read == 0 || pending.Length > 256L << 20)
                {
                    if (read == 0 && !File.Exists(basePath + ".atmos"))
                    {
                        return AudioOutcome.NoObjects;
                    }

                    await startTask.ConfigureAwait(false); // surfaces the solver's error
                    if (File.Exists(basePath + ".atmos"))
                    {
                        throw new InvalidDataException("Decoder output could not be placed.");
                    }

                    // A long stretch of decoded audio and still no DAMF header: an Atmos
                    // track names its objects from its first access units, so this is a
                    // plain surround track (a Blu-ray's 7.1 TrueHD). Say so instead of
                    // failing: a failure is retried, and decodes hundreds of MB each time.
                    throw new NoObjectsException();
                }

                if (read == 0)
                {
                    break;
                }

                continue;
            }

            if (read == 0)
            {
                break;
            }

            grid.Append(chunk.AsSpan(0, read));
            if (grid.ShouldStop)
            {
                _logger.LogInformation("Atmos session for {ItemId} stopping at segment {Segment}", itemId, session.NextSegment);
                await Task.WhenAll(encoding).ConfigureAwait(false);
                session.Cancellation.Cancel();
                return AudioOutcome.Stopped;
            }
        }

        grid?.Finish();
        await Task.WhenAll(encoding).ConfigureAwait(false);
        if (grid is null)
        {
            return AudioOutcome.NoObjects;
        }

        FinalizeLayout(itemId, state, grid.EndFrame);
        return AudioOutcome.Finished;
    }

    /// <summary>Segment bookkeeping for one session's PCM, fed by either decoder.</summary>
    private sealed class Grid
    {
        private readonly AtmosSceneService _owner;
        private readonly Guid _itemId;
        private readonly ItemState _state;
        private readonly LiveSession _session;
        private readonly SceneDocument _layout;
        private readonly int _frameBytes;
        private readonly int _segmentFrames;
        private readonly SemaphoreSlim _encoders;
        private readonly List<Task> _encoding;
        private readonly ISceneEventSource _events;
        private readonly byte[] _carry;
        private int _carryLength;
        private long _skipFrames;
        private int _segment;
        private byte[] _buffer;
        private int _filled;
        private int _cachedRun;

        public Grid(AtmosSceneService owner, Guid itemId, ItemState state, LiveSession session, SceneDocument layout,
            ISceneEventSource events, long startFrame, bool atStreamStart, int segmentFrames, SemaphoreSlim encoders, List<Task> encoding)
        {
            _owner = owner;
            _itemId = itemId;
            _state = state;
            _session = session;
            _layout = layout;
            _frameBytes = layout.Elements.Count * 3;
            _segmentFrames = segmentFrames;
            _encoders = encoders;
            _encoding = encoding;
            _events = events;
            _carry = new byte[_frameBytes];
            _buffer = new byte[segmentFrames * _frameBytes];

            if (atStreamStart && startFrame >= 0)
            {
                // The film's own start: pad up to the first sample instead of dropping a segment.
                _segment = (int)(startFrame / segmentFrames);
                _filled = (int)(startFrame - ((long)_segment * segmentFrames));
            }
            else
            {
                _segment = (int)((startFrame + segmentFrames - 1) / segmentFrames);
                _skipFrames = ((long)_segment * segmentFrames) - startFrame;
            }

            EndFrame = startFrame;
            session.NextSegment = _segment;
        }

        public bool ShouldStop { get; private set; }

        public bool ReachedEnd { get; private set; }

        public long EndFrame { get; private set; }

        public void Append(ReadOnlySpan<byte> data)
        {
            while (data.Length > 0)
            {
                if (_carryLength > 0 || data.Length < _frameBytes)
                {
                    var take = Math.Min(_frameBytes - _carryLength, data.Length);
                    data[..take].CopyTo(_carry.AsSpan(_carryLength));
                    _carryLength += take;
                    data = data[take..];
                    if (_carryLength == _frameBytes)
                    {
                        AddFrames(_carry);
                        _carryLength = 0;
                    }

                    continue;
                }

                var whole = data.Length / _frameBytes * _frameBytes;
                AddFrames(data[..whole]);
                data = data[whole..];
            }
        }

        private void AddFrames(ReadOnlySpan<byte> frames)
        {
            var count = frames.Length / _frameBytes;
            EndFrame += count;
            if (_skipFrames > 0)
            {
                var skip = (int)Math.Min(_skipFrames, count);
                _skipFrames -= skip;
                frames = frames[(skip * _frameBytes)..];
            }

            while (frames.Length > 0)
            {
                var take = Math.Min(frames.Length / _frameBytes, _segmentFrames - _filled);
                frames[..(take * _frameBytes)].CopyTo(_buffer.AsSpan(_filled * _frameBytes));
                _filled += take;
                frames = frames[(take * _frameBytes)..];
                if (_filled == _segmentFrames)
                {
                    CompleteSegment(_segmentFrames);
                }
            }
        }

        public void Finish()
        {
            ReachedEnd = true;
            if (_filled > 0)
            {
                CompleteSegment(_filled);
            }
        }

        private void CompleteSegment(int frames)
        {
            var segment = _segment;
            var buffer = _buffer;
            _segment++;
            _buffer = new byte[_segmentFrames * _frameBytes];
            _filled = 0;
            _session.NextSegment = _segment;

            var groups = _layout.Groups;
            if (_owner.IsComplete(_itemId, segment, groups.Count))
            {
                // Joined audio an earlier session already cached: nothing left to do here
                // unless this is the full prepare pass.
                if (++_cachedRun >= 2 && !_session.ToEnd && segment > _session.FirstSegment)
                {
                    ShouldStop = true;
                }

                return;
            }

            _cachedRun = 0;
            if (!_session.ToEnd && DateTime.UtcNow - _state.LastRequest > IdleStop)
            {
                ShouldStop = true;
            }

            var from = (long)segment * _segmentFrames;
            var events = _events.Segment(from, from + frames);
            WriteAtomically(_owner.EventsPath(_itemId, segment), JsonSerializer.SerializeToUtf8Bytes(events, JsonOptions));

            _encoders.Wait();
            _encoding.RemoveAll(t => t.IsCompletedSuccessfully);
            var channels = _layout.Elements.Count;
            _encoding.Add(Task.Run(async () =>
            {
                try
                {
                    for (var g = 0; g < groups.Count; g++)
                    {
                        var pcm = Deinterleave(buffer, frames, channels, groups[g]);
                        await _owner.EncodeFlacAsync(pcm, groups[g].Length, _owner.FlacPath(_itemId, segment, g)).ConfigureAwait(false);
                    }
                }
                finally
                {
                    _encoders.Release();
                }
            }));
        }
    }

    private SceneDocument WriteLayoutIfMissing(Guid itemId, ItemState state, ItemSource source, List<SceneElement> elements)
    {
        lock (state.Gate)
        {
            if (ReadLayout(itemId, state) is { } existing)
            {
                return existing;
            }

            var frameCount = (long)Math.Round(Math.Max(0, source.TrackSeconds) * SampleRate);
            var layout = new SceneDocument
            {
                SampleRate = SampleRate,
                FrameCount = frameCount,
                SegmentFrames = SegmentFrames,
                SegmentCount = (int)((frameCount + SegmentFrames - 1) / SegmentFrames),
                Groups = SplitGroups(elements.Count),
                StartSeconds = source.OriginMs / 1000,
                Elements = elements
            };
            WriteAtomically(ScenePath(itemId), JsonSerializer.SerializeToUtf8Bytes(layout, JsonOptions));
            state.Layout = layout;
            _logger.LogInformation("Atmos layout for {ItemId}: {Elements} elements, {Segments} segments (estimated)", itemId, elements.Count, layout.SegmentCount);
            return layout;
        }
    }

    /// <summary>A session reached the end: record the exact length, and whether every segment is now cached.</summary>
    private void FinalizeLayout(Guid itemId, ItemState state, long endFrame)
    {
        lock (state.Gate)
        {
            if (ReadLayout(itemId, state) is not { } layout)
            {
                return;
            }

            layout.FrameCount = endFrame;
            layout.FrameCountExact = true;
            layout.SegmentCount = (int)((endFrame + layout.SegmentFrames - 1) / layout.SegmentFrames);
            WriteAtomically(ScenePath(itemId), JsonSerializer.SerializeToUtf8Bytes(layout, JsonOptions));
            var complete = Enumerable.Range(0, layout.SegmentCount).All(n => IsComplete(itemId, n, layout.Groups.Count));
            if (complete)
            {
                File.WriteAllText(CompletePath(itemId), DateTime.UtcNow.ToString("O"));
            }

            _logger.LogInformation("Atmos decode for {ItemId} reached the end: {Frames} frames, cache complete {Complete}", itemId, endFrame, complete);
        }
    }

    /// <summary>Balanced groups of at most 8 channels: 14 → 7+7 rather than 8+6.</summary>
    private static List<int[]> SplitGroups(int channels)
    {
        var count = (channels + MaxChannelsPerGroup - 1) / MaxChannelsPerGroup;
        var groups = new List<int[]>();
        var next = 0;
        for (var g = 0; g < count; g++)
        {
            var size = (channels - next + (count - g) - 1) / (count - g);
            groups.Add(Enumerable.Range(next, size).ToArray());
            next += size;
        }

        return groups;
    }

    /// <summary>One group's channels out of interleaved 24-bit little-endian frames.</summary>
    private static byte[] Deinterleave(byte[] block, int frames, int channels, int[] group)
    {
        var output = new byte[frames * group.Length * 3];
        var o = 0;
        for (var f = 0; f < frames; f++)
        {
            var frameStart = f * channels * 3;
            foreach (var ch in group)
            {
                var i = frameStart + (ch * 3);
                output[o++] = block[i];
                output[o++] = block[i + 1];
                output[o++] = block[i + 2];
            }
        }

        return output;
    }

    private async Task EncodeFlacAsync(byte[] pcm, int channels, string path)
    {
        var tmp = path + ".tmp";
        using var process = StartProcess(_mediaEncoder.EncoderPath,
            ["-v", "error", "-f", "s24le", "-ar", SampleRate.ToString(CultureInfo.InvariantCulture),
             "-ac", channels.ToString(CultureInfo.InvariantCulture), "-i", "pipe:0",
             "-af", "aresample=osf=s16:dither_method=triangular",
             "-c:a", "flac", "-f", "flac", "-y", tmp],
            redirectInput: true);
        var stderr = process.StandardError.ReadToEndAsync();
        _ = process.StandardOutput.ReadToEndAsync();
        await process.StandardInput.BaseStream.WriteAsync(pcm).ConfigureAwait(false);
        process.StandardInput.Close();
        await process.WaitForExitAsync().ConfigureAwait(false);
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"FLAC encode of {Path.GetFileName(path)} failed: {(await stderr.ConfigureAwait(false)).Trim()}");
        }

        File.Move(tmp, path, overwrite: true);
    }

    /// <summary>
    /// Timestamp of the track's first packet (scene frame 0), and the file's
    /// start time, both on the file's own clock, in milliseconds.
    /// </summary>
    private (double OriginMs, double StartMs) ProbeOrigin(string mediaPath, int streamIndex, bool disc)
    {
        using var feed = disc ? DiscFeed.Start(Mvc3dPath, mediaPath, 0) : null;
        var args = new List<string>
        {
            "-v", "error", "-i", feed is null ? mediaPath : "pipe:0", "-select_streams", streamIndex.ToString(CultureInfo.InvariantCulture),
            "-read_intervals", "%+#1", "-show_entries", "packet=pts_time:format=start_time", "-of", "json"
        };
        using var process = StartProcess(_mediaEncoder.ProbePath, args, redirectInput: feed is not null);
        feed?.Connect(process);
        var output = process.StandardOutput.ReadToEnd();
        process.WaitForExit();
        return ParseOrigin(output);
    }

    /// <summary>The first packet's pts_time and the format's start_time from ffprobe's JSON, in ms (0 when absent).</summary>
    internal static (double OriginMs, double StartMs) ParseOrigin(string json)
    {
        static double Ms(JsonElement parent, string name) =>
            parent.ValueKind == JsonValueKind.Object && parent.TryGetProperty(name, out var value)
            && double.TryParse(value.GetString(), NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds)
                ? seconds * 1000
                : 0;
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            var packet = root.TryGetProperty("packets", out var packets) && packets.GetArrayLength() > 0 ? packets[0] : default;
            var format = root.TryGetProperty("format", out var f) ? f : default;
            return (Ms(packet, "pts_time"), Ms(format, "start_time"));
        }
        catch (JsonException)
        {
            return (0, 0);
        }
    }

    internal static void DeleteStale(string directory, string pattern)
    {
        if (!Directory.Exists(directory))
        {
            return;
        }

        foreach (var stale in Directory.GetDirectories(directory, pattern))
        {
            try
            {
                Directory.Delete(stale, recursive: true);
            }
            catch (IOException)
            {
            }
        }
    }

    private void MarkUnsupported(Guid itemId, string reason)
    {
        Directory.CreateDirectory(ItemDirectory(itemId));
        File.WriteAllText(UnsupportedPath(itemId), reason);
    }

    private static void WriteAtomically(string path, byte[] contents)
    {
        var tmp = path + ".tmp";
        File.WriteAllBytes(tmp, contents);
        File.Move(tmp, path, overwrite: true);
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

    private static Process StartProcess(string fileName, IEnumerable<string> args, bool redirectInput)
    {
        var info = new ProcessStartInfo(fileName)
        {
            RedirectStandardInput = redirectInput,
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
