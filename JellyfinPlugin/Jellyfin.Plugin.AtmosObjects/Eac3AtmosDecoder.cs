using System.Globalization;
using System.Numerics;
using Cavern;
using Cavern.Channels;
using Cavern.Format;
using Cavern.Format.Decoders;
using Cavern.Format.Renderers;
using Cavern.Format.Utilities;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// The E-AC-3 (Dolby Digital Plus + JOC) half of <see cref="AtmosSceneService"/>.
///
/// Unlike TrueHD, an E-AC-3 track needs no external process: the open-source
/// <a href="https://github.com/VoidXH/Cavern">Cavern</a> library decodes the JOC
/// objects in-process (NuGet packages <c>Cavern</c> and <c>Cavern.Format</c> — see
/// the plugin README's "Dependencies" section for the licence terms this requires:
/// Cavern must stay confined to the plugin and its use must be credited).
///
/// E-AC-3 frames are independently decodable (no cross-frame restart-interval
/// puzzle like TrueHD's <see cref="AtmosSceneService.FeedAsync"/>/<see
/// cref="StartSolver"/>), so this path is much simpler: ffmpeg copies the track
/// from a little before the target segment as a raw elementary stream on its
/// stdout, Cavern decodes that pipe as it arrives, a short warm-up
/// prefix is discarded so the JOC/OAMD ramp state has settled before the audio
/// that actually reaches the client, and the result is fed into the same
/// <see cref="AtmosSceneService.Grid"/> the TrueHD path uses — so segment files,
/// scene.json and Events are byte-for-byte the same shape either way.
///
/// The cut is streamed rather than written to a file first: extracting to the
/// end of a three-hour film means demuxing tens of GB before the first segment,
/// and on a USB disk that alone blows the ~1 s first-segment budget. Streaming
/// also bounds the work to what the session decodes: when the grid says stop
/// (cached region reached, or the viewer went idle) ffmpeg is killed with it.
/// </summary>
public sealed partial class AtmosSceneService
{
    /// <summary>
    /// How far before the target segment ffmpeg cuts the stream. E-AC-3 frames
    /// don't need TrueHD's multi-restart-interval alignment search, but the OAMD
    /// element state (gain/position ramps) still needs a few frames of runway
    /// before the point that is actually served, so the cut starts a little early
    /// and that much decoded audio is discarded rather than fed to the client.
    /// </summary>
    private const double Eac3PrerollSeconds = 0.75;

    /// <summary>
    /// Samples decoded per <see cref="EnhancedAC3Renderer.GetNextObjectSamples"/>
    /// call, i.e. how often object position/gain is sampled for events (~32 ms at
    /// 48 kHz) — fine enough for smooth ramps without an excessive event count.
    /// </summary>
    private const int Eac3Block = 1536;

    private async Task RunEac3SessionAsync(Guid itemId, ItemState state, ItemSource source, LiveSession session)
    {
        var ct = session.Cancellation.Token;
        var segmentFrames = SegmentFrames;
        var atStreamStart = session.FirstSegment == 0;
        var targetSeconds = session.FirstSegment * (double)Config.SegmentSeconds;
        var seekSeconds = atStreamStart ? 0 : Math.Max(0, (source.OriginMs / 1000) + targetSeconds - Eac3PrerollSeconds);
        Directory.CreateDirectory(Path.Combine(ItemDirectory(itemId), "seg"));
        _logger.LogInformation(
            "Atmos (EAC3) session for {ItemId}: segment {Segment}, seek {Seek:F1} s, to end {ToEnd}",
            itemId, session.FirstSegment, seekSeconds, session.ToEnd);

        // ffprobe's own seek lands on the same packet ffmpeg's stream copy
        // below will start from (same demuxer, same seek), so this is the
        // exact container time the cut begins at. The raw .ec3 elementary
        // stream ffmpeg writes carries no timestamps of its own to read this
        // back from afterwards, unlike the Matroska cut the TrueHD path takes.
        var landingMs = atStreamStart ? source.OriginMs : ProbePacketTimeMs(source.Path, source.StreamIndex, seekSeconds);

        var ffmpegArgs = new List<string> { "-v", "error", "-nostdin" };
        if (!atStreamStart)
        {
            ffmpegArgs.AddRange(["-ss", seekSeconds.ToString("F3", CultureInfo.InvariantCulture)]);
        }

        ffmpegArgs.AddRange(["-i", source.Path, "-map", $"0:{source.StreamIndex}", "-c", "copy", "-f", "eac3", "-"]);
        using var ffmpeg = StartProcess(_mediaEncoder.EncoderPath, ffmpegArgs, redirectInput: false);
        using var kill = ct.Register(() => TryKill(ffmpeg));
        var ffmpegErr = ffmpeg.StandardError.ReadToEndAsync(CancellationToken.None);
        var cut = new FullReadStream(ffmpeg.StandardOutput.BaseStream);
        try
        {
            var outcome = await DecodeEac3Async(itemId, state, source, session, cut, landingMs, atStreamStart, targetSeconds, segmentFrames, ct)
                .ConfigureAwait(false);
            _logger.LogInformation("Atmos (EAC3) session for {ItemId}: {Outcome} at segment {Segment}", itemId, outcome, session.NextSegment);

            if (outcome != AudioOutcome.Finished)
            {
                // Stopped or NoObjects: nothing more is needed from the cut.
                TryKill(ffmpeg);
            }

            await ffmpeg.WaitForExitAsync(ct).ConfigureAwait(false);
            if (outcome == AudioOutcome.NoObjects && cut.BytesRead == 0)
            {
                // An empty cut means ffmpeg never produced the track (a missing
                // file, say), which Cavern also reports as no objects. That is an
                // error to retry later, not a verdict to cache.
                throw new InvalidOperationException($"ffmpeg produced no EAC3 data (exit {ffmpeg.ExitCode}): {(await ffmpegErr.ConfigureAwait(false)).Trim()}");
            }

            if (outcome == AudioOutcome.Finished && ffmpeg.ExitCode != 0)
            {
                // A failed cut also ends the pipe early, which would otherwise read as the end of the film.
                throw new InvalidOperationException($"ffmpeg exited {ffmpeg.ExitCode} cutting the EAC3 track: {(await ffmpegErr.ConfigureAwait(false)).Trim()}");
            }

            if (outcome == AudioOutcome.NoObjects)
            {
                MarkUnsupported(itemId, "The EAC3 track has no JOC object presentation.");
            }
        }
        catch
        {
            TryKill(ffmpeg);
            throw;
        }
    }

    /// <summary>
    /// Decodes the streamed EAC3 cut with Cavern and feeds a <see cref="Grid"/>,
    /// discarding <see cref="Eac3PrerollSeconds"/> of warm-up audio first.
    /// </summary>
    private async Task<AudioOutcome> DecodeEac3Async(
        Guid itemId, ItemState state, ItemSource source, LiveSession session, FullReadStream ec3,
        double landingMs, bool atStreamStart, double targetSeconds, int segmentFrames, CancellationToken ct)
    {
        // Built directly rather than through AudioReader.Open, which wants a
        // seekable stream to size the file. Without a length the decoder can't
        // seek, which a live cut never needs, and reports its end through
        // Finished instead.
        var decoder = new EnhancedAC3Decoder(BlockBuffer<byte>.Create(ec3, 4096));
        var renderer = new EnhancedAC3Renderer(decoder);

        // Deliberately not `using (renderer)`: a plain (non-JOC) E-AC-3 track
        // decodes into Cavern's channel-based rendering branch, which never
        // constructs the JointObjectCodingApplier its own Dispose()
        // unconditionally disposes — Cavern.Format 2.1.0's
        // EnhancedAC3Renderer.Dispose() then NullReferenceExceptions
        // (confirmed against a plain-EAC3 test item). Only dispose it once
        // HasObjects is known true, where the applier really was built; the
        // no-objects early return below leaves it for the GC, which is safe
        // since nothing else here holds an unmanaged handle through it.
        if (!renderer.HasObjects || renderer.DynamicObjects == 0)
        {
            return AudioOutcome.NoObjects;
        }

        using (renderer)
        {
            var elements = BuildEac3Elements(renderer);
            var layout = WriteLayoutIfMissing(itemId, state, source, elements);

            var extractStartFrame = (long)Math.Round(((landingMs / 1000) - (source.OriginMs / 1000)) * SampleRate);
            var startFrame = atStreamStart ? 0L : (long)Math.Round(targetSeconds * SampleRate);
            var discardRemaining = Math.Max(0, startFrame - extractStartFrame);

            using var encoders = new SemaphoreSlim(Math.Max(1, Config.EncoderParallelism));
            var encoding = new List<Task>();
            var events = new CavernEventStream();
            var grid = new Grid(this, itemId, state, session, layout, events, startFrame, atStreamStart, segmentFrames, encoders, encoding);

            // One block is one E-AC-3 frame, and the decoder sets Finished once
            // it fails to read the header after the frame it just returned, so
            // checking before each block never drops or pads the last frame.
            long decoded = 0;
            while (!decoder.Finished)
            {
                ct.ThrowIfCancellationRequested();
                const int take = Eac3Block;
                var samples = renderer.GetNextObjectSamples(take);
                decoded += take;

                RecordEac3Events(events, renderer, elements, extractStartFrame + decoded, take);

                var pcm = InterleaveEac3(samples, take, elements.Count);
                if (discardRemaining > 0)
                {
                    var skip = (int)Math.Min(discardRemaining, take);
                    discardRemaining -= skip;
                    if (skip < take)
                    {
                        grid.Append(pcm.AsSpan(skip * elements.Count * 3));
                    }
                }
                else
                {
                    grid.Append(pcm);
                }

                if (grid.ShouldStop)
                {
                    await Task.WhenAll(encoding).ConfigureAwait(false);
                    session.Cancellation.Cancel();
                    return AudioOutcome.Stopped;
                }
            }

            grid.Finish();
            await Task.WhenAll(encoding).ConfigureAwait(false);
            FinalizeLayout(itemId, state, grid.EndFrame);
            return AudioOutcome.Finished;
        }
    }

    /// <summary>Beds (in <see cref="EnhancedAC3Renderer.GetStaticChannels"/> order) then dynamic objects, matching Cavern's own <c>Objects</c> ordering.</summary>
    private static List<SceneElement> BuildEac3Elements(EnhancedAC3Renderer renderer)
    {
        var beds = renderer.GetStaticChannels();
        var elements = new List<SceneElement>();
        foreach (var bed in beds)
        {
            elements.Add(new SceneElement { Id = elements.Count, Channel = elements.Count, Kind = "bed", BedChannel = BedChannelName(bed) });
        }

        for (var i = 0; i < renderer.DynamicObjects; i++)
        {
            elements.Add(new SceneElement { Id = elements.Count, Channel = elements.Count });
        }

        return elements;
    }

    private static string BedChannelName(ReferenceChannel channel) => channel switch
    {
        ReferenceChannel.ScreenLFE => "LFE",
        ReferenceChannel.FrontLeft => "L",
        ReferenceChannel.FrontRight => "R",
        ReferenceChannel.FrontCenter => "C",
        ReferenceChannel.RearLeft => "Ls",
        ReferenceChannel.RearRight => "Rs",
        ReferenceChannel.SideLeft => "Lss",
        ReferenceChannel.SideRight => "Rss",
        _ => channel.ToString()
    };

    /// <summary>
    /// Reads every element's position/gain as of the timeslot just decoded and
    /// hands it to <paramref name="events"/>. Only <c>kind: object</c> elements
    /// get a position — beds keep the fixed channel position Cavern assigns them,
    /// which isn't meaningful DAMF room-space and the client never asks for it.
    /// </summary>
    private static void RecordEac3Events(CavernEventStream events, EnhancedAC3Renderer renderer, List<SceneElement> elements, long frame, int rampFrames)
    {
        var objects = renderer.Objects;
        for (var i = 0; i < elements.Count; i++)
        {
            var obj = objects[i];
            var pos = elements[i].Kind == "object" ? ToDamfPosition(obj.Position) : null;
            var gainDb = obj.Volume <= 0f ? -144.0 : Math.Max(-144.0, 20.0 * Math.Log10(obj.Volume / 0.707f));
            events.Record(frame, elements[i].Id, pos, gainDb, rampFrames);
        }
    }

    /// <summary>
    /// Cavern's world-space object position to DAMF room space, worked out from
    /// <c>ObjectInfoBlock.UpdateSource</c> in Cavern.Format (Decoders/EnhancedAC3):
    /// that method's final line returns
    /// <c>Listener.EnvironmentSize * new Vector3(x*2-1, rawZ, y*-2+1)</c>, where
    /// <c>x</c>/<c>y</c>/<c>z</c> are the OAMD object's own room-relative
    /// left-right/front-back/floor-ceiling coordinates (each roughly 0..1, raw z
    /// roughly -1..1). So Cavern's world X is DAMF x directly (left -1..+1
    /// right); Cavern's world *Z* (not Y) carries the OAMD y (front-back) field
    /// and is DAMF y (back -1..+1 front — Cavern's Z-is-depth axis lines up with
    /// DAMF's y-is-depth axis, they're just named differently); Cavern's world Y
    /// (its up axis) carries the raw OAMD z (floor -1..ceiling +1) field and maps
    /// to DAMF z, clamped to 0..1 since DAMF has no below-ear-level convention
    /// (truehdd's own DAMF output for TrueHD never emits a negative z either).
    /// Verified against the Dolby Atmos demo: the two JOC objects the probe found
    /// pinned near the ceiling (maxY 1.0 in Cavern's own raw axis) come out with
    /// z within 0.01 of 1.0 through this mapping — see the plugin README.
    /// </summary>
    private static double[] ToDamfPosition(Vector3 cavernPosition)
    {
        var size = Listener.EnvironmentSize;
        var x = size.X == 0 ? 0 : cavernPosition.X / size.X;
        var y = size.Z == 0 ? 0 : cavernPosition.Z / size.Z;
        var z = size.Y == 0 ? 0 : Math.Clamp(cavernPosition.Y / size.Y, 0f, 1f);
        return [x, y, z];
    }

    /// <summary>float[element][sample] (-1..1) to interleaved 24-bit little-endian PCM, matching the TrueHD path's on-disk frame layout.</summary>
    private static byte[] InterleaveEac3(float[][] samples, int frames, int channels)
    {
        var output = new byte[frames * channels * 3];
        var o = 0;
        for (var f = 0; f < frames; f++)
        {
            for (var c = 0; c < channels; c++)
            {
                var clamped = Math.Clamp(samples[c][f], -1f, 1f);
                var value = (int)Math.Round(clamped * 8388607f); // 2^23 - 1
                output[o++] = (byte)value;
                output[o++] = (byte)(value >> 8);
                output[o++] = (byte)(value >> 16);
            }
        }

        return output;
    }
}

/// <summary>
/// Builds a <see cref="SceneEvent"/> keyframe list directly from decoded Cavern
/// object state (no metadata file to tail, unlike <see cref="DamfEventStream"/>):
/// every decode tick calls <see cref="Record"/>, which drops the update if
/// nothing changed enough to matter, keeping the event count bounded the same
/// way truehdd's own DAMF metadata only writes on a real change.
/// </summary>
public sealed class CavernEventStream : ISceneEventSource
{
    private const double PositionEpsilon = 1.0 / 512;
    private const double GainEpsilonDb = 0.1;

    private readonly Dictionary<int, List<SceneEvent>> _byElement = new();
    private readonly Dictionary<int, (double[]? Pos, double Gain)> _last = new();

    public void Record(long frame, int elementId, double[]? pos, double gainDb, int rampFrames)
    {
        if (_last.TryGetValue(elementId, out var previous) && Unchanged(previous, pos, gainDb))
        {
            return;
        }

        _last[elementId] = (pos, gainDb);
        if (!_byElement.TryGetValue(elementId, out var list))
        {
            _byElement[elementId] = list = [];
        }

        list.Add(new SceneEvent { Id = elementId, T = frame, Ramp = rampFrames, Gain = gainDb, Pos = pos });
    }

    public List<SceneEvent> Segment(long from, long to) => EventTimeline.Segment(_byElement, from, to);

    private static bool Unchanged((double[]? Pos, double Gain) previous, double[]? pos, double gainDb)
    {
        if (Math.Abs(previous.Gain - gainDb) > GainEpsilonDb)
        {
            return false;
        }

        if (previous.Pos is null || pos is null)
        {
            return previous.Pos is null && pos is null;
        }

        for (var i = 0; i < previous.Pos.Length; i++)
        {
            if (Math.Abs(previous.Pos[i] - pos[i]) > PositionEpsilon)
            {
                return false;
            }
        }

        return true;
    }
}

/// <summary>
/// A read-only stream wrapper whose reads return the full count asked for
/// unless the input has ended. Cavern's decoder treats a short read as the end
/// of the stream, and a pipe returns whatever ffmpeg has written so far: on a
/// slow disk the first read came back short and the session "finished" after
/// one frame.
/// </summary>
internal sealed class FullReadStream(Stream inner) : Stream
{
    /// <summary>Bytes returned so far; 0 after the decoder gave up means the input was empty.</summary>
    public long BytesRead { get; private set; }

    public override bool CanRead => true;

    public override bool CanSeek => false;

    public override bool CanWrite => false;

    public override long Length => throw new NotSupportedException();

    public override long Position
    {
        get => throw new NotSupportedException();
        set => throw new NotSupportedException();
    }

    public override int Read(byte[] buffer, int offset, int count)
    {
        var total = 0;
        while (total < count)
        {
            var read = inner.Read(buffer, offset + total, count - total);
            if (read == 0)
            {
                break;
            }

            total += read;
        }

        BytesRead += total;
        return total;
    }

    public override void Flush()
    {
    }

    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();

    public override void SetLength(long value) => throw new NotSupportedException();

    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
}
