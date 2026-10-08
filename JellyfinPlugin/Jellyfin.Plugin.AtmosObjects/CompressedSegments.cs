using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Globalization;
using System.Text.Json;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>The lossy codecs a segment bundle can carry.</summary>
public enum BundleCodec : ushort
{
    /// <summary>AAC in M4A, one mono stream per channel. Apple clients decode it in hardware or with the system codec.</summary>
    Aac = 1,
    /// <summary>Opus in Ogg, one mono stream per channel. For clients without an AAC decoder of their own (Android, Quest).</summary>
    Opus = 2
}

/// <summary>
/// A whole segment in one response, at a fraction of FLAC's size, for links
/// that can't carry lossless object audio (cellular). Made on request from
/// the segment's cached FLAC, so the decode pipeline is unchanged:
///
///   GET /AtmosObjects/{itemId}/Segments/{n}/Bundle?codec=aac|opus&amp;bitrate=64000&amp;budget=768000
///
/// <c>bitrate</c> is the average per audible channel and <c>budget</c> an
/// optional cap on the whole segment, both in bits per second. The bits are
/// not shared evenly: see <see cref="BundlePlanner"/>.
///
/// One request per segment whatever the channel count (a film with hundreds
/// of objects would otherwise be hundreds of requests every segment), and
/// every channel is its own mono stream: objects are rendered one by one, so
/// there is no stereo image for joint coding to exploit, and a mono stream
/// never runs into an encoder's channel-layout limits.
///
/// Format (little-endian), version 1:
///
///   0   "AOB1"
///   4   u16 version (1)
///   6   u16 codec (1 AAC/M4A, 2 Opus/Ogg)
///   8   u32 sample rate
///   12  u32 frames in the segment
///   16  u32 pre-roll frames
///   20  u32 channel count (the scene's channels, in channel order)
///   24  per channel, 12 bytes: u32 stream length (0: not sent), f32 RMS in
///       dBFS, f32 peak in dBFS, both as heard: the element's metadata gain
///       is added, so a channel its gain mutes reads silent
///   ..  the streams, in channel order
///
/// A channel that isn't sent is silent (peak under -80 dBFS) or, when the
/// budget couldn't cover everyone, audible and left out (peak above it).
///
/// Each stream decodes to pre-roll + frames samples. The pre-roll is the end
/// of the previous segment, so a lossy encoder starts warm and the join
/// between segments doesn't click; the client drops it. The level columns
/// let a client that can't decode everything in time keep the loudest
/// channels and silence the rest.
/// </summary>
public sealed partial class AtmosSceneService
{
    /// <summary>Frames of the previous segment each stream starts with: 100 ms, past AAC's and Opus's warm-up.</summary>
    private const int BundlePrerollFrames = 4800;
    /// <summary>Channels per encoder process, so a scene with hundreds of channels is several parallel runs rather than one with hundreds of inputs.</summary>
    private const int BundleChannelsPerRun = 64;
    /// <summary>What an M4A's sample tables add to a 10 s stream, per second of it (measured: a 16 kbps stream comes to 18.8). Ogg's pages cost nothing worth counting.</summary>
    private const int AacStreamOverhead = 2600;
    /// <summary>Below this peak a channel counts as silent and is left out: 3 LSB of 16-bit, just above the dither.</summary>
    private const float SilentPeakDb = -80;
    private static readonly byte[] BundleMagic = "AOB1"u8.ToArray();

    private readonly ConcurrentDictionary<string, Lazy<Task<string?>>> _bundleBuilds = new();

    /// <summary>"b2": the bits are planned per channel (BundlePlanner); bundles cut at a flat rate have no marker and are never read.</summary>
    private string BundlePath(Guid itemId, int segment, BundleCodec codec, int bitrate, int? budget)
        => Path.Combine(ItemDirectory(itemId), "seg",
            $"{segment}.{codec.ToString().ToLowerInvariant()}-{bitrate / 1000}k{(budget is int b ? $"-t{b / 1000}k" : "")}.b2.aob");

    /// <summary>
    /// The average per-channel bitrate a request may ask for, in whole steps of
    /// 8 kbps: each distinct value is a file kept on disk for every segment.
    /// </summary>
    public static int ClampBundleBitrate(int? bitrate) => Math.Clamp(((bitrate ?? 64000) + 4000) / 8000 * 8000, BundlePlanner.MinBitrate, BundlePlanner.MaxBitrate);

    /// <summary>The cap on a whole segment's bits per second, in steps of 32 kbps (64 kbps to 16 Mbps); null for none.</summary>
    public static int? ClampBundleBudget(int? budget)
        => budget is > 0 ? Math.Clamp(budget.Value / 32000 * 32000, 64000, 16_000_000) : null;

    /// <summary>
    /// The bundle for a segment that is already cached as FLAC, built if
    /// needed. Concurrent requests for the same bundle share one build.
    /// </summary>
    public async Task<string?> SegmentBundleAsync(Guid itemId, int segment, BundleCodec codec, int bitrate, int? budget, CancellationToken ct)
    {
        var path = BundlePath(itemId, segment, codec, bitrate, budget);
        if (File.Exists(path))
        {
            return path;
        }

        var build = _bundleBuilds.GetOrAdd(path, _ => new Lazy<Task<string?>>(() => BuildBundleAsync(itemId, segment, codec, bitrate, budget, path)));
        try
        {
            return await build.Value.WaitAsync(ct).ConfigureAwait(false);
        }
        finally
        {
            if (build.Value.IsCompleted)
            {
                _bundleBuilds.TryRemove(path, out _);
            }
        }
    }

    private async Task<string?> BuildBundleAsync(Guid itemId, int segment, BundleCodec codec, int bitrate, int? budget, string path)
    {
        var state = GetState(itemId);
        if (state is null || ReadLayout(itemId, state) is not { } layout)
        {
            return null;
        }

        var started = DateTime.UtcNow;
        var channels = layout.Elements.Count;
        var current = await ReadSegmentPcmAsync(itemId, segment, layout).ConfigureAwait(false);
        if (current is null)
        {
            return null;
        }

        var frames = current[0].Length;
        // The previous segment's tail warms the encoder. Without it (the
        // previous segment isn't decoded yet) the bundle is still served but
        // not kept, so a later play-through gets a join without a click.
        var previous = segment > 0 && IsComplete(itemId, segment - 1, layout.Groups.Count)
            ? await ReadSegmentPcmAsync(itemId, segment - 1, layout).ConfigureAwait(false)
            : null;
        var preroll = previous is null ? 0 : Math.Min(BundlePrerollFrames, previous[0].Length);

        var work = Path.Combine(Path.GetTempPath(), "atmos-bundle-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(work);
        try
        {
            // What each element's metadata does to it in this segment: where
            // it sits, and the loudest its gain gets. The gain is applied on
            // the client, so a channel it mutes is silent whatever its PCM
            // says, and every level below is as heard.
            var heard = ReadSegmentEvents(itemId, segment);
            var levels = new (float Rms, float Peak)[channels];
            var audible = new List<BundleSource>();
            for (var ch = 0; ch < channels; ch++)
            {
                var (rms, peak) = Levels(current[ch]);
                var element = layout.Elements[ch];
                var known = heard.TryGetValue(element.Id, out var meta);
                var gain = known ? meta.GainDb : 0f;
                levels[ch] = (Math.Max(-120f, rms + gain), Math.Max(-120f, peak + gain));
                // The FLAC was written with TPDF dither, so a silent channel
                // reads as ±1 LSB (-90 dBFS) of noise, not zero.
                if (levels[ch].Peak >= SilentPeakDb)
                {
                    audible.Add(new BundleSource(ch, IsLfe(element), levels[ch].Rms, known ? meta.Position : null));
                }
            }

            var plan = BundlePlanner.Plan(audible, bitrate, budget, codec == BundleCodec.Aac ? AacStreamOverhead : 0);
            foreach (var entry in plan.Encode)
            {
                var ch = entry.Channel;
                var mono = new byte[(preroll + frames) * 2];
                var o = 0;
                if (previous is not null)
                {
                    var tail = previous[ch];
                    for (var f = tail.Length - preroll; f < tail.Length; f++, o += 2)
                    {
                        BinaryPrimitives.WriteInt16LittleEndian(mono.AsSpan(o), tail[f]);
                    }
                }

                foreach (var sample in current[ch])
                {
                    BinaryPrimitives.WriteInt16LittleEndian(mono.AsSpan(o), sample);
                    o += 2;
                }

                await File.WriteAllBytesAsync(Path.Combine(work, $"{ch}.raw"), mono).ConfigureAwait(false);
            }

            using var limit = new SemaphoreSlim(Math.Max(1, Config.EncoderParallelism));
            await Task.WhenAll(plan.Encode.Chunk(BundleChannelsPerRun).Select(async batch =>
            {
                await limit.WaitAsync().ConfigureAwait(false);
                try
                {
                    await EncodeMonoStreamsAsync(work, batch, codec).ConfigureAwait(false);
                }
                finally
                {
                    limit.Release();
                }
            })).ConfigureAwait(false);

            var streams = new byte[channels][];
            foreach (var entry in plan.Encode)
            {
                streams[entry.Channel] = await File.ReadAllBytesAsync(Path.Combine(work, $"{entry.Channel}.{Extension(codec)}")).ConfigureAwait(false);
            }

            var bundle = Assemble(codec, layout.SampleRate, frames, preroll, levels, streams);
            if (preroll > 0 || segment == 0)
            {
                WriteAtomically(path, bundle);
                _logger.LogDebug("Bundle {Segment} {Codec} {Bitrate}/{Budget}: {Sent} sent of {Audible} audible of {Channels} channels ({Omitted} left out), {Planned} bps planned, {Bytes} bytes in {Ms} ms",
                    segment, codec, bitrate, budget, plan.Encode.Count, audible.Count, channels, plan.Omitted.Count, plan.TotalBitrate, bundle.Length, (DateTime.UtcNow - started).TotalMilliseconds);
                return path;
            }

            // Served once without a pre-roll; built again when asked after
            // its predecessor exists.
            var once = path + ".once";
            WriteAtomically(once, bundle);
            return once;
        }
        finally
        {
            try
            {
                Directory.Delete(work, recursive: true);
            }
            catch (IOException)
            {
            }
        }
    }

    /// <summary>A cached segment's channels as 16-bit samples, one array per scene channel.</summary>
    private async Task<short[][]?> ReadSegmentPcmAsync(Guid itemId, int segment, SceneDocument layout)
    {
        var channels = new short[layout.Elements.Count][];
        for (var g = 0; g < layout.Groups.Count; g++)
        {
            var group = layout.Groups[g];
            var flac = FlacPath(itemId, segment, g);
            if (!File.Exists(flac))
            {
                return null;
            }

            using var process = StartProcess(_mediaEncoder.EncoderPath,
                ["-v", "error", "-i", flac, "-f", "s16le", "-acodec", "pcm_s16le", "pipe:1"], redirectInput: false);
            var stderr = process.StandardError.ReadToEndAsync();
            using var pcm = new MemoryStream();
            await process.StandardOutput.BaseStream.CopyToAsync(pcm).ConfigureAwait(false);
            await process.WaitForExitAsync().ConfigureAwait(false);
            if (process.ExitCode != 0)
            {
                throw new InvalidOperationException($"Reading {Path.GetFileName(flac)} failed: {(await stderr.ConfigureAwait(false)).Trim()}");
            }

            var bytes = pcm.GetBuffer().AsSpan(0, (int)pcm.Length);
            var frames = bytes.Length / (2 * group.Length);
            for (var k = 0; k < group.Length; k++)
            {
                var samples = new short[frames];
                for (var f = 0; f < frames; f++)
                {
                    samples[f] = BinaryPrimitives.ReadInt16LittleEndian(bytes[(((f * group.Length) + k) * 2)..]);
                }

                channels[group[k]] = samples;
            }
        }

        return channels;
    }

    /// <summary>One encoder run for a batch of mono channels: an input and an output per channel, each at its own rate.</summary>
    private async Task EncodeMonoStreamsAsync(string work, ChannelPlan[] batch, BundleCodec codec)
    {
        var args = new List<string> { "-v", "error", "-y" };
        foreach (var entry in batch)
        {
            args.AddRange(["-f", "s16le", "-ar", SampleRate.ToString(CultureInfo.InvariantCulture), "-ac", "1", "-i", Path.Combine(work, $"{entry.Channel}.raw")]);
        }

        for (var i = 0; i < batch.Length; i++)
        {
            var rate = batch[i].Bitrate.ToString(CultureInfo.InvariantCulture);
            args.AddRange(["-map", $"{i}:a"]);
            args.AddRange(codec switch
            {
                // AAC-LC at every rate: jellyfin-ffmpeg's libfdk_aac is built
                // without HE-AAC ("Unable to set the AOT 5").
                BundleCodec.Aac => ["-c:a", "libfdk_aac", "-b:a", rate, "-f", "ipod"],
                _ => ["-c:a", "libopus", "-b:a", rate, "-application", "audio", "-f", "ogg"]
            });
            args.Add(Path.Combine(work, $"{batch[i].Channel}.{Extension(codec)}"));
        }

        using var process = StartProcess(_mediaEncoder.EncoderPath, args, redirectInput: false);
        var stderr = process.StandardError.ReadToEndAsync();
        _ = process.StandardOutput.ReadToEndAsync();
        await process.WaitForExitAsync().ConfigureAwait(false);
        if (process.ExitCode != 0)
        {
            throw new InvalidOperationException($"{codec} encode failed: {(await stderr.ConfigureAwait(false)).Trim()}");
        }
    }

    /// <summary>The low-frequency bed. Its name is whatever the DAMF header called it.</summary>
    private static bool IsLfe(SceneElement element)
        => element.Kind == "bed" && element.BedChannel?.StartsWith("LFE", StringComparison.OrdinalIgnoreCase) == true;

    /// <summary>
    /// Per element id, where it sits at the start of the segment and the
    /// loudest its gain gets within it. An element with no events has no entry.
    /// </summary>
    private Dictionary<int, (float[]? Position, float GainDb)> ReadSegmentEvents(Guid itemId, int segment)
    {
        var result = new Dictionary<int, (float[]? Position, float GainDb)>();
        var path = EventsPath(itemId, segment);
        if (!File.Exists(path))
        {
            return result;
        }

        List<SceneEvent>? events;
        try
        {
            events = JsonSerializer.Deserialize<List<SceneEvent>>(File.ReadAllBytes(path), JsonOptions);
        }
        catch (JsonException)
        {
            return result;
        }

        foreach (var group in (events ?? []).GroupBy(e => e.Id))
        {
            var ordered = group.OrderBy(e => e.T).ToList();
            var position = ordered.FirstOrDefault(e => e.Pos is { Length: >= 3 })?.Pos?.Select(v => (float)v).ToArray();
            result[group.Key] = (position, (float)ordered.Max(e => e.Gain));
        }

        return result;
    }

    private static string Extension(BundleCodec codec) => codec == BundleCodec.Aac ? "m4a" : "ogg";

    private static (float Rms, float Peak) Levels(short[] samples)
    {
        double sum = 0;
        var peak = 0;
        foreach (var s in samples)
        {
            sum += (double)s * s;
            peak = Math.Max(peak, Math.Abs((int)s));
        }

        static float Db(double linear) => linear <= 0 ? -120f : (float)Math.Max(-120, 20 * Math.Log10(linear));
        return (Db(Math.Sqrt(sum / Math.Max(1, samples.Length)) / 32768), Db(peak / 32768.0));
    }

    private static byte[] Assemble(BundleCodec codec, int sampleRate, int frames, int preroll, (float Rms, float Peak)[] levels, byte[][] streams)
    {
        var header = 24 + (12 * levels.Length);
        var total = header + streams.Sum(s => s?.Length ?? 0);
        var bundle = new byte[total];
        var span = bundle.AsSpan();
        BundleMagic.CopyTo(span);
        BinaryPrimitives.WriteUInt16LittleEndian(span[4..], 1);
        BinaryPrimitives.WriteUInt16LittleEndian(span[6..], (ushort)codec);
        BinaryPrimitives.WriteUInt32LittleEndian(span[8..], (uint)sampleRate);
        BinaryPrimitives.WriteUInt32LittleEndian(span[12..], (uint)frames);
        BinaryPrimitives.WriteUInt32LittleEndian(span[16..], (uint)preroll);
        BinaryPrimitives.WriteUInt32LittleEndian(span[20..], (uint)levels.Length);
        var offset = header;
        for (var ch = 0; ch < levels.Length; ch++)
        {
            var entry = span[(24 + (12 * ch))..];
            var stream = streams[ch];
            BinaryPrimitives.WriteUInt32LittleEndian(entry, (uint)(stream?.Length ?? 0));
            BinaryPrimitives.WriteSingleLittleEndian(entry[4..], levels[ch].Rms);
            BinaryPrimitives.WriteSingleLittleEndian(entry[8..], levels[ch].Peak);
            if (stream is not null)
            {
                stream.CopyTo(span[offset..]);
                offset += stream.Length;
            }
        }

        return bundle;
    }
}
