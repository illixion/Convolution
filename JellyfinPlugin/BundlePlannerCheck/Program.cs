using Jellyfin.Plugin.AtmosObjects;
int fails = 0;
void Check(bool ok, string what) { if (!ok) { fails++; Console.WriteLine("FAIL: " + what); } else Console.WriteLine("ok:   " + what); }
BundleSource Obj(int ch, float level, float[]? pos = null) => new(ch, false, level, pos);

// 1. All channels equal and unpositioned: everyone gets the average.
var flat = Enumerable.Range(0, 8).Select(i => Obj(i, -20)).ToList();
var p = BundlePlanner.Plan(flat, 64000, null);
Check(p.Encode.All(c => c.Bitrate == 64000) && p.Omitted.Count == 0, "equal channels get the average");

// 2. LFE gets a quarter (min 16k), others share the saving, total preserved.
var withLfe = new List<BundleSource> { new(0, true, -20, null) };
withLfe.AddRange(Enumerable.Range(1, 8).Select(i => Obj(i, -20)));
p = BundlePlanner.Plan(withLfe, 64000, null);
var lfe = p.Encode.Single(c => c.Channel == 0);
Check(lfe.Bitrate == 21000, $"LFE at a third of the average ({lfe.Bitrate})");
Check(p.Encode.Where(c => c.Channel != 0).All(c => c.Bitrate is >= 69000 and <= 71000), $"others share the saving ({string.Join(",", p.Encode.Select(c => c.Bitrate))})");
Check(p.TotalBitrate <= 64000 * 9 && p.TotalBitrate > 64000 * 9 - 9000, $"total {p.TotalBitrate} within a kbps per channel of {64000 * 9}");

// 3. Dialogue (front centre) and the front stage outweigh the rest.
var stage = new List<BundleSource> {
  Obj(0, -20, new[] { 0f, 1f, 0f }), Obj(1, -20, new[] { -1f, 1f, 0f }), Obj(2, -20, new[] { 1f, 1f, 0f }),
  Obj(3, -20, new[] { -1f, -1f, 0f }), Obj(4, -20, new[] { 1f, -1f, 0f }), Obj(5, -20, new[] { 0f, 0f, 1f }) };
p = BundlePlanner.Plan(stage, 64000, null);
int R(int ch) => p.Encode.Single(c => c.Channel == ch).Bitrate;
Check(R(0) > R(1) && R(1) > R(3) && R(3) == R(5), $"centre {R(0)} > front L {R(1)} > surround {R(3)} = height {R(5)}");
Check(p.TotalBitrate <= 64000 * 6 && p.TotalBitrate > 64000 * 6 - 6000, $"total preserved ({p.TotalBitrate})");

// 4. Quiet channels give up bits, never below half the average.
var levels = new List<BundleSource> { Obj(0, -15), Obj(1, -20), Obj(2, -60), Obj(3, -80) };
p = BundlePlanner.Plan(levels, 64000, null);
Check(R(2) < R(1) && R(3) == p.Encode.Min(c => c.Bitrate) && p.Encode.All(c => c.Bitrate >= 32000), $"quiet channels: {string.Join(",", p.Encode.Select(c => c.Bitrate))}");
Check(p.Encode.All(c => c.Bitrate <= 128000), "none over twice the average");

// 5. A budget below what everyone needs: floors fall to 16k, then the quietest are left out; the total never exceeds it.
var many = Enumerable.Range(0, 40).Select(i => Obj(i, -20 - i)).ToList();
p = BundlePlanner.Plan(many, 64000, 400000);
Check(p.TotalBitrate <= 400000, $"total {p.TotalBitrate} within the 400000 budget");
Check(p.Encode.Count + p.Omitted.Count == 40 && p.Omitted.Count > 0, $"{p.Omitted.Count} omitted");
Check(p.Omitted.All(o => o > 10) && p.Encode.All(c => c.Bitrate >= 16000), "the quietest are the ones omitted; none under 16 kbps");
Check(p.Encode.Count == 25, $"keeps {p.Encode.Count} at 16 kbps (400k / 16k = 25)");

// 6. Hundreds of channels, a budget of 2 Mbps.
var hundreds = Enumerable.Range(0, 300).Select(i => Obj(i, -20 - (i % 30))).ToList();
p = BundlePlanner.Plan(hundreds, 64000, 2_000_000);
Check(p.TotalBitrate <= 2_000_000 && p.Encode.Count >= 100, $"300 channels: {p.Encode.Count} kept, total {p.TotalBitrate}");

// 6b. A budget is for what is sent: each stream's container comes out of it.
p = BundlePlanner.Plan(many, 64000, 400000, streamOverhead: 2600);
Check(p.TotalBitrate + (p.Encode.Count * 2600) <= 400000, $"with 2.6 kbps of container per stream: {p.Encode.Count} kept, {p.TotalBitrate} + {p.Encode.Count * 2600} within 400000");
Check(p.Encode.Count == 21, $"keeps {p.Encode.Count} (400k / 18.6k = 21)");

// 7. Budget above what the average would spend changes nothing.
p = BundlePlanner.Plan(flat, 64000, 10_000_000);
Check(p.Encode.All(c => c.Bitrate == 64000), "a generous budget is no cap");

// 8. Activity curve.
Check(Math.Abs(BundlePlanner.Activity(0) - 1) < 1e-6 && Math.Abs(BundlePlanner.Activity(48) - 0.4492f) < 0.01f && BundlePlanner.Activity(100) == 0.45f, "activity: 1 within 12 dB, 0.45 at 48 dB");

// 9. Pool never negative with an LFE and a tiny budget.
p = BundlePlanner.Plan(withLfe, 64000, 64000);
Check(p.TotalBitrate <= 64000, $"tiny budget: {p.Encode.Count} kept, total {p.TotalBitrate}");
Console.WriteLine(fails == 0 ? "ALL OK" : $"{fails} FAILED");
return fails;
