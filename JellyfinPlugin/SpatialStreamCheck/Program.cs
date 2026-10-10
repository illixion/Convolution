using Jellyfin.Plugin.AtmosObjects;
int fails = 0, checks = 0;
void Check(bool ok, string what) { checks++; if (!ok) { fails++; Console.WriteLine("FAIL: " + what); } else Console.WriteLine("ok:   " + what); }

// 1. The playlist, exactly: the query on every URI, the last segment what remains.
var info = new SpatialInfo { Spatial = true, Segments = 3, SegmentSeconds = 4, DurationSeconds = 10.5 };
var playlist = SpatialPlaylist.Build(info, "?api_key=abc&x=1");
const string expected = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-PLAYLIST-TYPE:VOD\n#EXT-X-INDEPENDENT-SEGMENTS\n"
    + "#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-MAP:URI=\"init.mp4?api_key=abc&x=1\"\n"
    + "#EXTINF:4.00000,\nSegments/0.m4s?api_key=abc&x=1\n"
    + "#EXTINF:4.00000,\nSegments/1.m4s?api_key=abc&x=1\n"
    + "#EXTINF:2.50000,\nSegments/2.m4s?api_key=abc&x=1\n"
    + "#EXT-X-ENDLIST\n";
Check(playlist == expected, "playlist text, query forwarded, last segment 2.5 s");
if (playlist != expected) Console.WriteLine(playlist);

// 2. A fractional segment length rounds TARGETDURATION up; no query leaves bare URIs.
playlist = SpatialPlaylist.Build(new SpatialInfo { Segments = 2, SegmentSeconds = 2.5, DurationSeconds = 5 }, "");
Check(playlist.Contains("#EXT-X-TARGETDURATION:3\n") && playlist.Contains("URI=\"init.mp4\"") && playlist.Contains("\nSegments/1.m4s\n"),
    "TARGETDURATION rounds 2.5 s up to 3; empty query");
Check(playlist.Contains("#EXTINF:2.50000,\nSegments/1.m4s"), "a last segment that fills the grid lasts a full segment");

// 3. A duration short of the grid floors the last segment at a millisecond.
playlist = SpatialPlaylist.Build(new SpatialInfo { Segments = 3, SegmentSeconds = 4, DurationSeconds = 7.5 }, "");
Check(playlist.Contains("#EXTINF:0.00100,\nSegments/2.m4s"), "last segment floored at 0.001 s");
Check(SpatialPlaylist.Build(new SpatialInfo { Segments = 1, SegmentSeconds = 4, DurationSeconds = 1.25 }, "").Contains("#EXTINF:1.25000,\nSegments/0.m4s"),
    "a single segment lasts the whole video");

// 4. Follow distance: 30 s of segments, at least 2.
Check(SpatialRunPlanner.FollowSegments(4, 30) == 8, "follow 8 segments at 4 s");
Check(SpatialRunPlanner.FollowSegments(10, 30) == 3, "follow 3 segments at 10 s");
Check(SpatialRunPlanner.FollowSegments(30, 30) == 2 && SpatialRunPlanner.FollowSegments(20, 30) == 2, "follow never under 2");

// 5. Run ranges.
var none = new Func<int, bool>(_ => false);
Check(SpatialRunPlanner.LastSegment(0, 100, 4, 120, none) == 29, "a run from 0 covers 120 s: 30 segments of 4 s");
Check(SpatialRunPlanner.LastSegment(0, 100, 7, 120, none) == 17, "120 s of 7 s segments rounds up to 18");
Check(SpatialRunPlanner.LastSegment(85, 100, 4, 120, none) == 99, "a run near the end stops at the last segment");
Check(SpatialRunPlanner.LastSegment(99, 100, 4, 120, none) == 99, "a run at the last segment converts just it");
Check(SpatialRunPlanner.LastSegment(3, 100, 4, 1, none) == 3, "a run is at least one segment");
Check(SpatialRunPlanner.LastSegment(5, 100, 4, 120, n => n is 10 or 20) == 9, "a run stops before the first cached segment after it");
Check(SpatialRunPlanner.LastSegment(5, 100, 4, 120, n => n == 5) == 34, "the run's own first segment being cached doesn't stop it");
Check(SpatialRunPlanner.LastSegment(5, 100, 4, 120, n => n == 6) == 5, "a cached next segment leaves a one-segment run");
Check(SpatialRunPlanner.LastSegment(5, 100, 4, 120, n => n == 40) == 34, "a cached segment past the run's end doesn't shorten it");

// 6. Coverage and cancelling on a seek.
var behindRun = new SpatialRunProgress(false, 10, 39, 12);
Check(behindRun.Covers(10, 8) && behindRun.Covers(15, 8) && behindRun.Covers(20, 8), "covers from its first segment to next + follow");
Check(!behindRun.Covers(21, 8), "not past next + follow");
Check(!behindRun.Covers(9, 8), "not before its first segment");
Check(!new SpatialRunProgress(false, 10, 15, 12).Covers(16, 8), "not past its last segment");
Check(!(behindRun with { Finished = true }).Covers(12, 8), "a finished run covers nothing");
var aheadRun = new SpatialRunProgress(false, 50, 79, 50);
var runs = new[] { ("old", behindRun), ("new", aheadRun) };
var seekAhead = SpatialRunPlanner.Superseded(runs, r => r.Item2, 52, 8).Select(r => r.Item1).ToList();
Check(seekAhead.SequenceEqual(["old"]), $"a seek ahead to 52 stops the run at 10, not the one at 50 ({string.Join(",", seekAhead)})");
var seekBehind = SpatialRunPlanner.Superseded(runs, r => r.Item2, 5, 8).Select(r => r.Item1).ToList();
Check(seekBehind.SequenceEqual(["old", "new"]), $"a seek behind to 5 stops both ({string.Join(",", seekBehind)})");
var follow = SpatialRunPlanner.Superseded(runs, r => r.Item2, 18, 8).Select(r => r.Item1).ToList();
Check(follow.SequenceEqual(["new"]), $"playing on at 18 keeps the run at 10 ({string.Join(",", follow)})");

// 7. The run limit stops the runs asked for least recently.
var t = new DateTime(2026, 10, 10, 12, 0, 0, DateTimeKind.Utc);
var active = new[] { ("b", t.AddSeconds(20)), ("c", t.AddSeconds(30)), ("a", t.AddSeconds(10)) };
string Names(IEnumerable<(string, DateTime)> rs) => string.Join(",", rs.Select(r => r.Item1));
var stop = SpatialRunPlanner.OverLimit(active, r => r.Item2, 2);
Check(Names(stop) == "a,b", $"limit 2 with 3 running and one starting stops the two oldest ({Names(stop)})");
stop = SpatialRunPlanner.OverLimit(active, r => r.Item2, 3);
Check(Names(stop) == "a", $"limit 3 stops the oldest ({Names(stop)})");
Check(SpatialRunPlanner.OverLimit(active, r => r.Item2, 4).Count == 0, "limit 4 stops none");
Check(SpatialRunPlanner.OverLimit(active, r => r.Item2, 0).Count == 3, "limit 0 counts as 1: the new run alone");
Check(SpatialRunPlanner.OverLimit(Array.Empty<(string, DateTime)>(), r => r.Item2, 1).Count == 0, "nothing running: nothing to stop");

// 8. Trimming.
Check(SpatialCacheTrimmer.BudgetBytes(100) == 512L * 1024 * 1024 && SpatialCacheTrimmer.BudgetBytes(4096) == 4096L * 1024 * 1024, "budget never under 512 MB");
var grace = TimeSpan.FromMinutes(2);
SpatialCacheFile F(string path, long bytes, double accessMinutesAgo, double writeMinutesAgo) =>
    new(path, bytes, t.AddMinutes(-accessMinutesAgo), t.AddMinutes(-writeMinutesAgo));
var cache = new[]
{
    F("/c/x/9.m4s", 40, 20, 25), F("/c/y/1.m4s", 40, 1, 60), F("/c/x/2.m4s", 40, 30, 30),
    F("/c/y/.3.m4s", 1000, 90, 90), F("/c/x/5.m4s", 40, 10, 40)
};
string Paths(IEnumerable<SpatialCacheFile> fs) => string.Join(",", fs.Select(f => f.Path));
var drop = SpatialCacheTrimmer.ToDelete(cache, 100, t, grace);
Check(Paths(drop) == "/c/x/9.m4s,/c/x/2.m4s", $"over 100 bytes: the least recently used go, across items ({Paths(drop)})");
Check(drop.All(f => !Path.GetFileName(f.Path).StartsWith('.')), "a temporary dot-file is never deleted");
Check(SpatialCacheTrimmer.ToDelete(cache, 160, t, grace).Count == 0, "160 bytes holds all four: the dot-file's 1000 aren't counted");
Check(SpatialCacheTrimmer.ToDelete(cache, 1000, t, grace).Count == 0, "under budget nothing goes");
var recent = new[] { F("/c/a.m4s", 40, 0.5, 0.5), F("/c/b.m4s", 40, 30, 1.5), F("/c/c.m4s", 40, 1, 30), F("/c/d.m4s", 40, 3, 3) };
drop = SpatialCacheTrimmer.ToDelete(recent, 10, t, grace);
Check(Paths(drop) == "/c/d.m4s", $"files served or written within 2 minutes stay even over budget ({Paths(drop)})");

// 9. info.json validity.
var stored = new SpatialInfo { Spatial = true, SourceBytes = 1234, SourceTicks = 5678 };
Check(SpatialInfoCache.IsCurrent(stored, 1234, 5678), "same size and time: reused");
Check(!SpatialInfoCache.IsCurrent(stored, 1235, 5678), "changed size: not reused");
Check(!SpatialInfoCache.IsCurrent(stored, 1234, 5679), "changed time: not reused");
Check(!SpatialInfoCache.IsCurrent(null, 1234, 5678), "no info.json: not reused");
Check(SpatialInfoCache.ShouldStore(stored, true), "a spatial answer is stored");
Check(SpatialInfoCache.ShouldStore(new SpatialInfo { Reason = "one view: not spatial video" }, true), "vergence's one-view answer is stored");
Check(!SpatialInfoCache.ShouldStore(new SpatialInfo { Reason = "vergence not found at /x" }, false), "vergence missing: not stored");
Check(!SpatialInfoCache.ShouldStore(new SpatialInfo { Reason = "vergence exited 1" }, false), "vergence failing: not stored");

Console.WriteLine(fails == 0 ? $"ALL OK ({checks} checks)" : $"{fails} of {checks} FAILED");
return fails;
