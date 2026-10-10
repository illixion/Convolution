using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Controller.Library;
using MediaBrowser.Controller.MediaEncoding;
using MediaBrowser.Model.Entities;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>The video index a client reads: one segment per keyframe interval (GOP).</summary>
public sealed class VideoIndex
{
    public int Version { get; set; } = 1;
    /// <summary>Presentation time of each segment's first frame (a keyframe), in container seconds.</summary>
    public List<double> SegmentStarts { get; set; } = [];
    public double DurationSeconds { get; set; }
    public string Codec { get; set; } = string.Empty;
    /// <summary>Jellyfin's range type (SDR, HDR10, DOVI, DOVIWithHDR10, DOVIWithEL, …).</summary>
    public string VideoRange { get; set; } = string.Empty;
    public int? DvProfile { get; set; }
    /// <summary>True when the segments carry the Dolby Vision configuration (dvh1 + dvvC/dvcC).</summary>
    public bool DolbyVision { get; set; }
    /// <summary>
    /// The lower picture tiers on offer, largest first (2160p source:
    /// [1440, 1080]; 1080p: none). Each is fetched with <c>?height=</c> on
    /// Init and Segments and cut on this same index (see <see cref="VideoTiers"/>).
    /// </summary>
    public List<int> PictureHeights { get; set; } = [];
}

/// <summary>
/// Serves an item's video track, copied untouched, as fragmented-MP4 segments
/// in film time, so a client can drive its own renderer from the same clock as
/// the Atmos audio.
///
/// Segments are keyframe intervals taken from the Matroska Cues, so every
/// segment starts with a frame a decoder can start from and any segment can
/// be fetched on its own. A request for a segment that is not cached starts a
/// run: jellyfin-ffmpeg seeks, copies the video out through its HLS muxer
/// (fMP4 segments, split at every keyframe) for <see cref="RunSeconds"/>, and
/// each finished segment is moved into the cache. Two quirks are handled
/// here rather than trusted to ffmpeg flags:
///
/// - The seek can land a keyframe interval earlier than asked. A second
///   output (mkvtimestamp_v2) reports the first packet's original decode
///   time, which identifies the keyframe the run actually starts on.
/// - The HLS muxer rebases timestamps to start at zero. Each segment's tfdt
///   is shifted back so its first frame presents at the keyframe's film time.
///
///   &lt;cache&gt;/v2/&lt;itemId&gt;/video/index.json
///   &lt;cache&gt;/v2/&lt;itemId&gt;/video/init.mp4
///   &lt;cache&gt;/v2/&lt;itemId&gt;/video/&lt;n&gt;.m4s
///
/// The segments are the film's own bitstream, so a full cache would duplicate
/// the file; the least recently used segments are dropped beyond
/// <see cref="PluginConfiguration.VideoCacheMegabytes"/> per item.
///
/// A lower picture tier (<c>height</c> 1440 or 1080, <see cref="VideoTiers"/>)
/// is made the same way with the codec arguments swapped: the run decodes,
/// scales and encodes HEVC, with a keyframe forced at every index segment
/// start inside it and none of the encoder's own, so the muxer still splits
/// exactly once per index segment and the same matching and tfdt shift
/// apply. Each tier is cached in its own folder (<c>video/&lt;height&gt;/</c>),
/// under the item's one budget, and its runs are its own: a seek in one tier
/// leaves another tier's runs alone.
/// </summary>
public sealed class VideoSegmentService
{
    /// <summary>Film seconds one run copies before it stops; a later request starts the next.</summary>
    private const double RunSeconds = 120;
    /// <summary>How far ahead of a run's progress a request still waits for it instead of starting another.</summary>
    private const int FollowSegments = 8;
    private static readonly TimeSpan SegmentWait = TimeSpan.FromSeconds(45);
    /// <summary>How far a produced segment may present from its indexed start (see <see cref="NearestSegment"/>).</summary>
    private const double MatchToleranceSeconds = 0.010;

    private readonly ILibraryManager _libraryManager;
    private readonly IMediaSourceManager _mediaSourceManager;
    private readonly IMediaEncoder _mediaEncoder;
    private readonly IApplicationPaths _paths;
    private readonly ILogger<VideoSegmentService> _logger;
    private readonly ConcurrentDictionary<Guid, ItemState> _items = new();

    public VideoSegmentService(
        ILibraryManager libraryManager,
        IMediaSourceManager mediaSourceManager,
        IMediaEncoder mediaEncoder,
        IApplicationPaths paths,
        ILogger<VideoSegmentService> logger)
    {
        _libraryManager = libraryManager;
        _mediaSourceManager = mediaSourceManager;
        _mediaEncoder = mediaEncoder;
        _paths = paths;
        _logger = logger;
    }

    private static PluginConfiguration Config => Plugin.Instance?.Configuration ?? new PluginConfiguration();

    private string ItemDirectory(Guid itemId) => Path.Combine(
        string.IsNullOrWhiteSpace(Config.CacheDirectory) ? Path.Combine(_paths.CachePath, "atmos-objects") : Config.CacheDirectory,
        "v2",
        itemId.ToString("N"),
        "video");

    private string IndexPath(Guid itemId) => Path.Combine(ItemDirectory(itemId), "index.json");

    /// <summary>Where a tier's init and segments go: the item's video folder for the original, a subfolder per lower tier.</summary>
    private string TierDirectory(Guid itemId, int? height) =>
        height is int h ? Path.Combine(ItemDirectory(itemId), h.ToString(CultureInfo.InvariantCulture)) : ItemDirectory(itemId);

    private string InitPath(Guid itemId, int? height) => Path.Combine(TierDirectory(itemId, height), "init.mp4");

    private string SegmentPath(Guid itemId, int segment, int? height) => Path.Combine(TierDirectory(itemId, height), $"{segment}.m4s");

    // MARK: Client entry points

    /// <summary>The item's video index, or null for unknown items and files without a seek index.</summary>
    public VideoIndex? GetIndex(Guid itemId) => GetState(itemId)?.Index;

    /// <summary>Whether <paramref name="height"/> (null: the original) is a tier this item offers.</summary>
    public bool OffersTier(Guid itemId, int? height) =>
        height is not int h || GetState(itemId)?.Index?.PictureHeights.Contains(h) == true;

    /// <summary>
    /// Path of a tier's init segment. Any run of the tier writes it, so a
    /// running one (a client that asked for its segment first, as a tier
    /// change does) is waited for; with none, a run makes segment 0 alone.
    /// A longer one would go on encoding the film's opening alongside the
    /// run the client's next request starts where it is playing.
    /// </summary>
    public async Task<string?> EnsureInitAsync(Guid itemId, int? height, CancellationToken ct)
    {
        var path = InitPath(itemId, height);
        if (File.Exists(path))
        {
            return path;
        }

        var state = GetState(itemId);
        if (state?.Index is null || !OffersTier(itemId, height))
        {
            return null;
        }

        state.LastRequest = DateTime.UtcNow;
        var deadline = DateTime.UtcNow + SegmentWait;
        var started = 0;
        while (DateTime.UtcNow < deadline)
        {
            if (File.Exists(path))
            {
                return path;
            }

            lock (state.Gate)
            {
                if (!state.Runs.Any(r => !r.Finished && r.Height == height))
                {
                    if (started++ >= 2)
                    {
                        return null;
                    }

                    StartRun(itemId, state, 0, height, initOnly: true);
                }
            }

            await Task.Delay(50, ct).ConfigureAwait(false);
        }

        return null;
    }

    /// <summary>
    /// Path of segment <paramref name="segment"/> of a tier (null: the
    /// original, copied out of the film; else transcoded to that height).
    /// </summary>
    public async Task<string?> EnsureSegmentAsync(Guid itemId, int segment, int? height, CancellationToken ct)
    {
        var state = GetState(itemId);
        if (state?.Index is not { } index || segment < 0 || segment >= index.SegmentStarts.Count || !OffersTier(itemId, height))
        {
            return null;
        }

        state.LastRequest = DateTime.UtcNow;
        var path = SegmentPath(itemId, segment, height);
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
                if (!state.Runs.Any(r => r.Height == height && r.Covers(segment)))
                {
                    // Two runs that both finished without producing it: give up.
                    if (started++ >= 2)
                    {
                        return null;
                    }

                    StartRun(itemId, state, segment, height);
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
        public required string MediaPath { get; init; }
        public VideoIndex? Index;
        public readonly List<Run> Runs = [];
        public DateTime LastRequest = DateTime.UtcNow;
    }

    private sealed class Run
    {
        public required int FirstSegment { get; init; }
        public required int LastSegment { get; init; }
        /// <summary>The tier: null copies the original, else the height it is transcoded to.</summary>
        public required int? Height { get; init; }
        /// <summary>Made for an init request: one segment, and no seek cancels it.</summary>
        public bool InitOnly { get; init; }
        public volatile int NextSegment;
        public volatile bool Finished;
        public readonly CancellationTokenSource Cancellation = new();

        public bool Covers(int segment) => !Finished && segment >= FirstSegment && segment <= LastSegment
            && segment <= NextSegment + FollowSegments;
    }

    private ItemState? GetState(Guid itemId)
    {
        if (_items.TryGetValue(itemId, out var existing))
        {
            return existing;
        }

        var item = _libraryManager.GetItemById(itemId);
        if (item is null || string.IsNullOrEmpty(item.Path))
        {
            return null;
        }

        var state = new ItemState { MediaPath = item.Path };
        // Runs left by a server stopped mid-copy.
        AtmosSceneService.DeleteStale(ItemDirectory(itemId), "run-*");
        try
        {
            state.Index = LoadIndex(itemId, item.Path, item.RunTimeTicks);
        }
        catch (Exception ex) when (ex is IOException or EndOfStreamException or UnauthorizedAccessException)
        {
            _logger.LogWarning(ex, "Could not index video for {ItemId}", itemId);
        }

        return _items.GetOrAdd(itemId, state);
    }

    private VideoIndex? LoadIndex(Guid itemId, string mediaPath, long? runTimeTicks)
    {
        var stream = _mediaSourceManager.GetMediaStreams(itemId).FirstOrDefault(s => s.Type == MediaStreamType.Video);
        if (File.Exists(IndexPath(itemId)))
        {
            var cached = JsonSerializer.Deserialize<VideoIndex>(File.ReadAllText(IndexPath(itemId)), AtmosSceneService.JsonOptions);
            if (cached is not null)
            {
                // Not kept in index.json: it follows the configuration, and
                // an index written before tiers existed has none.
                cached.PictureHeights = OfferedHeights(stream, cached);
            }

            return cached;
        }

        var keyframes = MatroskaCues.ReadVideoKeyframes(mediaPath);
        if (stream is null || keyframes is null)
        {
            _logger.LogWarning("No video stream or Matroska Cues for {ItemId}; video segments are unavailable", itemId);
            return null;
        }

        // A single-layer Dolby Vision stream (profiles 5, 8, 10) keeps its
        // configuration; profile 7's enhancement layer is not decodable on
        // Apple hardware, so it is served as its HDR10 base layer.
        var dvProfile = stream.DvProfile;
        var index = new VideoIndex
        {
            SegmentStarts = keyframes,
            DurationSeconds = runTimeTicks is long ticks ? TimeSpan.FromTicks(ticks).TotalSeconds : keyframes[^1],
            Codec = stream.Codec ?? string.Empty,
            VideoRange = stream.VideoRangeType.ToString(),
            DvProfile = dvProfile,
            DolbyVision = dvProfile is 5 or 8 or 10
        };
        Directory.CreateDirectory(ItemDirectory(itemId));
        var tmp = IndexPath(itemId) + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(index, AtmosSceneService.JsonOptions));
        File.Move(tmp, IndexPath(itemId), overwrite: true);
        index.PictureHeights = OfferedHeights(stream, index);
        _logger.LogInformation("Indexed video for {ItemId}: {Count} segments, {Range}, tiers [{Tiers}]", itemId, keyframes.Count,
            index.VideoRange, string.Join(",", index.PictureHeights));
        return index;
    }

    /// <summary>The lower tiers this picture gets: none without an encoder, or with tiers turned off.</summary>
    private List<int> OfferedHeights(MediaStream? stream, VideoIndex index) =>
        Config.PictureTiers && Encoder() is not null
            ? VideoTiers.Offered(stream?.Width, stream?.Height, index.VideoRange, index.DvProfile, Reshape() is not null)
            : [];

    private readonly object _encoderGate = new();
    private TierEncoder? _encoder;
    private TierReshape? _reshape;
    private bool _encoderProbed;

    /// <summary>How this server applies a profile 5 RPU for a tier, asked once with the encoder.</summary>
    private TierReshape? Reshape()
    {
        Encoder();
        lock (_encoderGate)
        {
            return _reshape;
        }
    }

    /// <summary>The HEVC encoder jellyfin-ffmpeg has, asked once.</summary>
    private TierEncoder? Encoder()
    {
        lock (_encoderGate)
        {
            if (_encoderProbed)
            {
                return _encoder;
            }

            _encoderProbed = true;
            try
            {
                using var ffmpeg = StartProcess(_mediaEncoder.EncoderPath, ["-hide_banner", "-encoders"]);
                var stderr = ffmpeg.StandardError.ReadToEndAsync();
                var listing = ffmpeg.StandardOutput.ReadToEnd();
                ffmpeg.WaitForExit(10_000);
                _encoder = VideoTiers.PickEncoder(listing);

                using var filters = StartProcess(_mediaEncoder.EncoderPath, ["-hide_banner", "-filters"]);
                var filtersStderr = filters.StandardError.ReadToEndAsync();
                var filtersListing = filters.StandardOutput.ReadToEnd();
                filters.WaitForExit(10_000);
                _reshape = VideoTiers.PickReshape(filtersListing, _encoder);
            }
            catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception or IOException)
            {
                _logger.LogWarning(ex, "Could not list ffmpeg's encoders; lower picture tiers are off");
            }

            _logger.LogInformation("Picture tiers encode with {Encoder}; Dolby Vision profile 5 converts with {Reshape}",
                _encoder?.ToString() ?? "nothing (no HEVC encoder)", _reshape?.ToString() ?? "nothing (no tiers for it)");
            return _encoder;
        }
    }

    // MARK: Runs

    private void StartRun(Guid itemId, ItemState state, int segment, int? height, bool initOnly = false)
    {
        var index = state.Index!;
        var starts = index.SegmentStarts;
        var last = segment;
        while (!initOnly && last + 1 < starts.Count && starts[last + 1] - starts[segment] < RunSeconds)
        {
            last++;
        }

        // A seek elsewhere makes runs for the old position pointless; a
        // client changing tier may still be fed from the other one.
        foreach (var old in state.Runs.Where(r => !r.Finished && !r.InitOnly && r.Height == height
                     && (segment < r.FirstSegment || segment > r.LastSegment)))
        {
            old.Cancellation.Cancel();
        }

        var run = new Run { FirstSegment = segment, LastSegment = last, NextSegment = segment, Height = height, InitOnly = initOnly };
        state.Runs.RemoveAll(r => r.Finished);
        state.Runs.Add(run);
        _ = Task.Run(async () =>
        {
            try
            {
                await ExecuteRunAsync(itemId, state, run).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (run.Cancellation.IsCancellationRequested)
            {
                _logger.LogInformation("Video run for {ItemId} ({Tier}) at segment {Segment} cancelled at {Next}", itemId, TierName(height), segment, run.NextSegment);
            }
            catch (Exception ex)
            {
                _logger.LogError(ex, "Video run for {ItemId} ({Tier}) at segment {Segment} failed", itemId, TierName(height), segment);
            }
            finally
            {
                run.Finished = true;
            }
        });
    }

    private async Task ExecuteRunAsync(Guid itemId, ItemState state, Run run)
    {
        var ct = run.Cancellation.Token;
        var index = state.Index!;
        var starts = index.SegmentStarts;
        var dir = ItemDirectory(itemId);
        var work = Path.Combine(dir, "run-" + Guid.NewGuid().ToString("N")[..8]);
        Directory.CreateDirectory(work);
        Directory.CreateDirectory(TierDirectory(itemId, run.Height));

        // Seek just past the keyframe (never past the next one), and stop just
        // after the run's last segment so the muxer closes it at its keyframe.
        var first = starts[run.FirstSegment];
        var seek = run.FirstSegment == 0 ? 0 : Math.Min(first + 0.05, NextStart(starts, run.FirstSegment) - 0.001);
        var end = run.LastSegment + 1 < starts.Count ? starts[run.LastSegment + 1] + 0.5 : index.DurationSeconds + 1;
        // A copy's -t counts from the seek point; a transcode's from its
        // first decoded frame, which may be a keyframe interval earlier, so
        // it is given that interval more (what it makes past the end is
        // dropped as cut short, below).
        var duration = run.Height is null || run.FirstSegment == 0 ? end - seek : end - starts[run.FirstSegment - 1];
        var args = new List<string> { "-v", "error", "-nostdin", "-y" };
        var reshape = run.Height is not null && VideoTiers.NeedsReshape(index.VideoRange, index.DvProfile)
            ? Reshape() ?? throw new InvalidOperationException("ffmpeg can't apply a Dolby Vision profile 5 RPU.")
            : (TierReshape?)null;
        args.AddRange(VideoTiers.InputArguments(reshape));
        if (seek > 0)
        {
            args.AddRange(["-ss", Seconds(seek)]);
        }

        if (run.Height is not null)
        {
            // Decoding starts at the keyframe the demuxer lands on, as a copy
            // does. An accurate seek would drop it and the frames up to the
            // seek point, so the run would start on a frame of the encoder's choosing.
            args.Add("-noaccurate_seek");
        }

        args.AddRange(["-t", Seconds(duration), "-i", state.MediaPath,
            "-map", "0:v:0", "-map_chapters", "-1", "-map_metadata", "-1"]);
        if (run.Height is int height)
        {
            // Only the codec differs from a copy: the same muxing follows.
            // The tier's arguments tag it hvc1 and carry no Dolby Vision.
            var encoder = Encoder() ?? throw new InvalidOperationException("ffmpeg has no HEVC encoder.");
            var transfer = VideoTiers.Transfer(index.VideoRange, index.DvProfile, reshape is not null)
                ?? throw new InvalidOperationException($"A {index.VideoRange} picture can't be transcoded.");
            args.AddRange(VideoTiers.EncodeArguments(encoder, height, transfer,
                VideoTiers.ForcedKeyframes(starts, run.FirstSegment, run.LastSegment), reshape));
            args.AddRange(["-copyts", "-avoid_negative_ts", "disabled"]);
        }
        else
        {
            args.AddRange(["-c:v", "copy", "-copyts", "-avoid_negative_ts", "disabled"]);
            if (index.DolbyVision)
            {
                // -strict unofficial is what makes the mp4 muxer write dvcC/dvvC.
                args.AddRange(["-tag:v", "dvh1", "-strict", "unofficial"]);
            }
            else if (string.Equals(index.Codec, "hevc", StringComparison.OrdinalIgnoreCase))
            {
                args.AddRange(["-tag:v", "hvc1"]);
            }
        }

        args.AddRange(["-f", "hls", "-hls_segment_type", "fmp4", "-hls_time", "0.01", "-hls_list_size", "0",
            "-hls_playlist_type", "vod", "-hls_flags", "temp_file",
            "-hls_fmp4_init_filename", "init.mp4",
            "-hls_segment_filename", Path.Combine(work, "seg%d.m4s"),
            Path.Combine(work, "run.m3u8"),
            "-map", "0:v:0", "-c:v", "copy", "-copyts", "-f", "mkvtimestamp_v2", "pipe:1"]);

        _logger.LogInformation("Video run for {ItemId} ({Tier}): segments {First}-{Last}, seek {Seek:F3} s", itemId, TierName(run.Height), run.FirstSegment, run.LastSegment, seek);
        using var ffmpeg = StartProcess(_mediaEncoder.EncoderPath, args);
        using var kill = ct.Register(() => TryKill(ffmpeg));
        var stderr = ffmpeg.StandardError.ReadToEndAsync(CancellationToken.None);
        var firstDts = new TaskCompletionSource<double>(TaskCreationOptions.RunContinuationsAsynchronously);
        var timestamps = Task.Run(async () =>
        {
            // "# timecode format v2", then one decode time in ms per packet.
            // Only the first matters, but the pipe must be drained to the end.
            while (await ffmpeg.StandardOutput.ReadLineAsync(CancellationToken.None).ConfigureAwait(false) is { } line)
            {
                if (!firstDts.Task.IsCompleted && double.TryParse(line, NumberStyles.Float, CultureInfo.InvariantCulture, out var ms))
                {
                    firstDts.TrySetResult(ms / 1000);
                }
            }

            firstDts.TrySetException(new InvalidOperationException("ffmpeg reported no video packets."));
        }, CancellationToken.None);

        try
        {
            var dts = await firstDts.Task.WaitAsync(ct).ConfigureAwait(false);
            // The first packet is the run's first keyframe: the earliest segment start at or after its decode time.
            var firstSegment = starts.FindIndex(s => s >= dts - 0.0005);
            if (firstSegment < 0)
            {
                throw new InvalidOperationException($"No keyframe at or after decode time {dts:F3} s.");
            }

            long? delta = null;
            uint timescale = 0;
            var produced = 0;
            while (true)
            {
                var exited = ffmpeg.HasExited;
                var next = Path.Combine(work, $"seg{produced}.m4s");
                var after = Path.Combine(work, $"seg{produced + 1}.m4s");
                if (!File.Exists(next) || (!File.Exists(after) && !exited))
                {
                    if (exited && !File.Exists(next))
                    {
                        break;
                    }

                    await Task.Delay(50, ct).ConfigureAwait(false);
                    continue;
                }

                // seg{produced} is complete: the next one has started, or ffmpeg is done.
                if (timescale == 0)
                {
                    var init = await File.ReadAllBytesAsync(Path.Combine(work, "init.mp4"), ct).ConfigureAwait(false);
                    timescale = Fmp4.Timescale(init) ?? throw new InvalidOperationException("Init segment has no timescale.");
                    if (!File.Exists(InitPath(itemId, run.Height)))
                    {
                        WriteAtomically(InitPath(itemId, run.Height), Fmp4.WithoutEmptyEdits(init));
                    }
                }

                var data = await File.ReadAllBytesAsync(next, ct).ConfigureAwait(false);
                var pts = Fmp4.FirstPresentationTime(data) ?? throw new InvalidOperationException($"seg{produced} has no samples.");
                delta ??= (long)Math.Round(starts[firstSegment] * timescale) - pts;
                var filmSeconds = (pts + delta.Value) / (double)timescale;
                var segment = NearestSegment(starts, filmSeconds);
                // The muxer's last segment is closed by -t, half a second
                // into the interval after the run's last: cut short, unless
                // it is the film's own last. It used to be cached as that
                // next segment, which then played half a second and froze.
                if (segment is { } cut && cut != starts.Count - 1 && !File.Exists(after))
                {
                    _logger.LogDebug("Video run for {ItemId} ({Tier}): segment {Segment} ends with the run, dropped as cut short", itemId, TierName(run.Height), cut);
                }
                else if (segment is { } n)
                {
                    Fmp4.ShiftDecodeTimes(data, delta.Value);
                    if (!File.Exists(SegmentPath(itemId, n, run.Height)))
                    {
                        WriteAtomically(SegmentPath(itemId, n, run.Height), data);
                    }

                    run.NextSegment = n + 1;
                }
                else
                {
                    _logger.LogWarning("Video run for {ItemId} ({Tier}): segment at {Seconds:F3} s matches no keyframe in the index", itemId, TierName(run.Height), filmSeconds);
                }

                File.Delete(next);
                produced++;
            }

            await ffmpeg.WaitForExitAsync(ct).ConfigureAwait(false);
            if (ffmpeg.ExitCode != 0)
            {
                throw new InvalidOperationException($"ffmpeg exited {ffmpeg.ExitCode}: {(await stderr.ConfigureAwait(false)).Trim()}");
            }

            _logger.LogInformation("Video run for {ItemId} ({Tier}): {Count} segments from {First}", itemId, TierName(run.Height), produced, firstSegment);
            TrimCache(itemId);
        }
        finally
        {
            TryKill(ffmpeg);
            await Task.WhenAny(timestamps, Task.Delay(TimeSpan.FromSeconds(2), CancellationToken.None)).ConfigureAwait(false);
            try
            {
                Directory.Delete(work, recursive: true);
            }
            catch (IOException)
            {
            }
        }
    }

    private static double NextStart(List<double> starts, int segment) => segment + 1 < starts.Count ? starts[segment + 1] : double.MaxValue;

    /// <summary>
    /// The segment whose indexed start is nearest <paramref name="seconds"/>,
    /// if it is within <see cref="MatchToleranceSeconds"/> and well inside
    /// the gap to its neighbours. The Cues are not exact: Baby Driver's
    /// segment 1893 is indexed at 1664.872 s and presents at 1664.870 s, after
    /// a one-frame segment. A fixed 2 ms window rejected it, so the segment
    /// was never written and the client asked for it forever while the
    /// audio played on. Keyframes are at least a frame apart, so a match
    /// within 40% of the gap can't be the neighbour.
    /// </summary>
    private static int? NearestSegment(List<double> starts, double seconds)
    {
        var i = starts.BinarySearch(seconds);
        if (i < 0)
        {
            i = ~i;
        }

        int? best = null;
        foreach (var candidate in new[] { i - 1, i })
        {
            if (candidate >= 0 && candidate < starts.Count
                && (best is not { } b || Math.Abs(starts[candidate] - seconds) < Math.Abs(starts[b] - seconds)))
            {
                best = candidate;
            }
        }

        if (best is not { } n)
        {
            return null;
        }

        var gap = Math.Min(n > 0 ? starts[n] - starts[n - 1] : double.MaxValue,
            n + 1 < starts.Count ? starts[n + 1] - starts[n] : double.MaxValue);
        var tolerance = Math.Min(MatchToleranceSeconds, gap * 0.4);
        return Math.Abs(starts[n] - seconds) <= tolerance ? n : null;
    }

    /// <summary>
    /// Drops the least recently used segments beyond the per-item budget,
    /// which every tier shares (a run's own working folder is left alone).
    /// </summary>
    private void TrimCache(Guid itemId)
    {
        var budget = Math.Max(256, Config.VideoCacheMegabytes) * 1024L * 1024L;
        var folders = new[] { (int?)null }.Concat(VideoTiers.Heights.Select(h => (int?)h))
            .Select(h => new DirectoryInfo(TierDirectory(itemId, h)))
            .Where(d => d.Exists);
        var files = folders.SelectMany(d => d.GetFiles("*.m4s"))
            .OrderByDescending(f => f.LastAccessTimeUtc)
            .ToList();
        long total = 0;
        foreach (var file in files)
        {
            total += file.Length;
            if (total > budget)
            {
                file.Delete();
            }
        }
    }

    private static string TierName(int? height) => height is int h ? $"{h}p" : "original";

    private static string Seconds(double value) => value.ToString("F3", CultureInfo.InvariantCulture);

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
