using System.Diagnostics.CodeAnalysis;
using System.Globalization;
using System.Text;

namespace Jellyfin.Plugin.AtmosObjects;

// The decisions SpatialStreamService makes, without the files, processes and
// Jellyfin services around them, so SpatialStreamCheck can run them alone.

/// <summary>The side-by-side stream's HLS media playlist.</summary>
internal static class SpatialPlaylist
{
    /// <summary>
    /// The playlist for the whole video. Every segment but the last lasts
    /// <see cref="SpatialInfo.SegmentSeconds"/>; the last is what remains of
    /// the duration (at least a millisecond). <paramref name="query"/> (with
    /// its leading <c>?</c>, or empty) is appended to every URI.
    /// </summary>
    public static string Build(SpatialInfo info, string query)
    {
        var text = new StringBuilder();
        text.Append("#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n");
        text.Append(CultureInfo.InvariantCulture, $"#EXT-X-TARGETDURATION:{(int)Math.Ceiling(info.SegmentSeconds)}\n");
        text.Append("#EXT-X-MEDIA-SEQUENCE:0\n");
        text.Append(CultureInfo.InvariantCulture, $"#EXT-X-MAP:URI=\"init.mp4{query}\"\n");
        for (var n = 0; n < info.Segments; n++)
        {
            var duration = n == info.Segments - 1
                ? Math.Max(0.001, info.DurationSeconds - (n * info.SegmentSeconds))
                : info.SegmentSeconds;
            text.Append(CultureInfo.InvariantCulture, $"#EXTINF:{duration:0.00000},\nSegments/{n}.m4s{query}\n");
        }

        text.Append("#EXT-X-ENDLIST\n");
        return text.ToString();
    }
}

/// <summary>Where a run stands: the segments it was started for and the next one it will write.</summary>
internal readonly record struct SpatialRunProgress(bool Finished, int FirstSegment, int LastSegment, int NextSegment)
{
    /// <summary>
    /// Whether a request for <paramref name="segment"/> should wait for this
    /// run: it is still going, the segment is in its range, and no more than
    /// <paramref name="follow"/> segments past what it has written.
    /// </summary>
    public bool Covers(int segment, int follow) => !Finished && segment >= FirstSegment && segment <= LastSegment
        && segment <= NextSegment + follow;
}

/// <summary>Which segments a run converts, and which runs a new one stops.</summary>
internal static class SpatialRunPlanner
{
    /// <summary>How many segments past a run's progress still count as covered: <paramref name="followSeconds"/> of video, at least 2.</summary>
    public static int FollowSegments(double segmentSeconds, double followSeconds) =>
        Math.Max(2, (int)Math.Ceiling(followSeconds / segmentSeconds));

    /// <summary>
    /// The last segment of a run from <paramref name="first"/>: up to
    /// <paramref name="runSeconds"/> of video (at least one segment), never
    /// past the end, and stopping before the first segment after
    /// <paramref name="first"/> that <paramref name="exists"/> says is cached.
    /// </summary>
    public static int LastSegment(int first, int segments, double segmentSeconds, double runSeconds, Func<int, bool> exists)
    {
        var last = Math.Min(segments - 1, first + Math.Max(1, (int)Math.Ceiling(runSeconds / segmentSeconds)) - 1);
        for (var n = first + 1; n <= last; n++)
        {
            if (exists(n))
            {
                return n - 1;
            }
        }

        return last;
    }

    /// <summary>The runs a new run at <paramref name="segment"/> makes pointless: those that don't cover it.</summary>
    public static IEnumerable<T> Superseded<T>(IEnumerable<T> runs, Func<T, SpatialRunProgress> progress, int segment, int follow) =>
        runs.Where(r => !progress(r).Covers(segment, follow));

    /// <summary>
    /// The runs to stop so that, with one more starting, no more than
    /// <paramref name="limit"/> (at least 1) run at once: those whose item
    /// was asked for least recently. <paramref name="active"/> excludes the
    /// run being started and runs already stopping.
    /// </summary>
    public static IReadOnlyList<T> OverLimit<T>(IEnumerable<T> active, Func<T, DateTime> lastRequest, int limit)
    {
        var ordered = active.OrderBy(lastRequest).ToList();
        return ordered.Take(Math.Max(0, ordered.Count + 1 - Math.Max(1, limit))).ToList();
    }
}

/// <summary>One cached segment, as the trimmer sees it.</summary>
internal readonly record struct SpatialCacheFile(string Path, long Bytes, DateTime LastAccessUtc, DateTime LastWriteUtc)
{
    /// <summary>When it was last served or written, whichever is later.</summary>
    public DateTime LastUsedUtc => LastAccessUtc > LastWriteUtc ? LastAccessUtc : LastWriteUtc;
}

/// <summary>Which cached segments go when the cache is over its budget.</summary>
internal static class SpatialCacheTrimmer
{
    /// <summary>The budget for a configured size: never under 512 MB.</summary>
    public static long BudgetBytes(int megabytes) => Math.Max(512, megabytes) * 1024L * 1024L;

    /// <summary>
    /// Keeps the most recently used files up to <paramref name="budgetBytes"/>
    /// and returns the rest, except files served or written within
    /// <paramref name="grace"/> of <paramref name="now"/>. Temporary files
    /// (names starting with a dot) are neither counted nor deleted.
    /// </summary>
    public static IReadOnlyList<SpatialCacheFile> ToDelete(IEnumerable<SpatialCacheFile> files, long budgetBytes, DateTime now, TimeSpan grace)
    {
        var cutoff = now - grace;
        long total = 0;
        var drop = new List<SpatialCacheFile>();
        foreach (var file in files
            .Where(f => !System.IO.Path.GetFileName(f.Path).StartsWith('.'))
            .OrderByDescending(f => f.LastUsedUtc))
        {
            total += file.Bytes;
            if (total > budgetBytes && file.LastAccessUtc < cutoff && file.LastWriteUtc < cutoff)
            {
                drop.Add(file);
            }
        }

        return drop;
    }
}

/// <summary>When an item's info.json can be trusted, and when it is written.</summary>
internal static class SpatialInfoCache
{
    /// <summary>Whether <paramref name="cached"/> was read from the file as it is now (same size and modification time).</summary>
    public static bool IsCurrent([NotNullWhen(true)] SpatialInfo? cached, long sourceBytes, long sourceTicks) =>
        cached is not null && cached.SourceBytes == sourceBytes && cached.SourceTicks == sourceTicks;

    /// <summary>
    /// Whether to keep <paramref name="info"/> in info.json: when vergence
    /// read the file and answered, spatial or one view. Not when it couldn't
    /// run, failed or timed out, so installing or updating it later works
    /// without a restart; the cheap answers given without vergence (not
    /// MOV/MP4, not HEVC) are worked out again each time.
    /// </summary>
    public static bool ShouldStore(SpatialInfo info, bool vergenceAnswered) => info.Spatial || vergenceAnswered;
}
