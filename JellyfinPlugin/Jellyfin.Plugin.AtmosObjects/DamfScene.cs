using System.Globalization;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// The scene document a client reads: which audio channel carries which
/// Atmos element and how the audio is split into segment files. Frames count
/// from the TrueHD track's first access unit.
/// </summary>
public sealed class SceneDocument
{
    /// <summary>2: events are served per segment (<c>Segments/{n}/Events</c>), not in this document.</summary>
    public int Version { get; set; } = 2;
    public int SampleRate { get; set; }
    /// <summary>Estimated from the item's runtime until a decode has reached the end.</summary>
    public long FrameCount { get; set; }
    public bool FrameCountExact { get; set; }
    public int SegmentFrames { get; set; }
    public int SegmentCount { get; set; }
    /// <summary>Audio channel indices carried by each group's FLAC file, in file channel order.</summary>
    public List<int[]> Groups { get; set; } = [];
    /// <summary>Start time of the TrueHD track in the container, for lining up with video.</summary>
    public double StartSeconds { get; set; }
    public List<SceneElement> Elements { get; set; } = [];
    /// <summary>
    /// What <c>Segments/{n}/Bundle</c> can serve besides the FLAC groups.
    /// A client that finds it missing (an older plugin) stays on FLAC.
    /// </summary>
    public string[] BundleCodecs { get; set; } = ["aac", "opus"];
}

public sealed class SceneElement
{
    public int Id { get; set; }
    public int Channel { get; set; }
    public string Kind { get; set; } = "object";
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? BedChannel { get; set; }
}

public sealed class SceneEvent
{
    public int Id { get; set; }
    public long T { get; set; }
    public int Ramp { get; set; }
    public double Gain { get; set; }
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public double[]? Pos { get; set; }
}

/// <summary>
/// Reads the DAMF header truehdd writes (&lt;base&gt;.atmos). YAML, but in the
/// fixed shape truehdd emits, so a line reader is enough.
/// </summary>
public static partial class DamfReader
{
    [GeneratedRegex(@"- channel: (\w+)\s+ID: (\d+)")]
    private static partial Regex BedRegex();

    [GeneratedRegex(@"^\s+- ID: (\d+)\s*$", RegexOptions.Multiline)]
    private static partial Regex ObjectRegex();

    /// <summary>Elements in audio channel order: beds first, then objects, as the header lists them.</summary>
    public static List<SceneElement> ReadElements(string headerPath)
    {
        var header = File.ReadAllText(headerPath);
        var elements = new List<SceneElement>();
        foreach (Match m in BedRegex().Matches(header))
        {
            elements.Add(new SceneElement
            {
                Id = int.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture),
                Channel = elements.Count,
                Kind = "bed",
                BedChannel = m.Groups[1].Value
            });
        }

        var objectsAt = header.IndexOf("objects:", StringComparison.Ordinal);
        if (objectsAt >= 0)
        {
            foreach (Match m in ObjectRegex().Matches(header[objectsAt..]))
            {
                elements.Add(new SceneElement
                {
                    Id = int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture),
                    Channel = elements.Count
                });
            }
        }

        return elements;
    }
}

/// <summary>
/// Something that can produce the events for a scene segment, keyed by frame
/// range. TrueHD (<see cref="DamfEventStream"/>, via <see cref="DamfEventSource"/>)
/// and EAC3 (<see cref="CavernEventStream"/>) each fill their own per-element
/// keyframe lists from a different decoder, then share the same cut-to-segment
/// logic in <see cref="EventTimeline"/>.
/// </summary>
public interface ISceneEventSource
{
    List<SceneEvent> Segment(long from, long to);
}

/// <summary>
/// The snapshot-plus-ramp segment cut shared by every <see cref="ISceneEventSource"/>:
/// events are stored as one keyframe list per element id, and a segment opens
/// with each element's interpolated state at <paramref name="from"/> so it can
/// be used on its own, followed by the keyframes that fall inside the range.
/// </summary>
public static class EventTimeline
{
    public static List<SceneEvent> Segment(Dictionary<int, List<SceneEvent>> byElement, long from, long to)
    {
        var result = new List<SceneEvent>();
        foreach (var (id, events) in byElement)
        {
            var snapshot = StateAt(events, from);
            if (snapshot is not null)
            {
                result.Add(snapshot);
            }

            result.AddRange(events.Where(e => e.T > from && e.T < to));
        }

        result.Sort((a, b) => a.T != b.T ? a.T.CompareTo(b.T) : a.Id.CompareTo(b.Id));
        return result;
    }

    private static SceneEvent? StateAt(List<SceneEvent> events, long frame)
    {
        var index = events.FindLastIndex(e => e.T <= frame);
        if (index < 0)
        {
            return null;
        }

        var key = events[index];
        double[]? pos = key.Pos;
        var gain = key.Gain;
        if (index > 0 && key.Ramp > 0 && frame < key.T + key.Ramp)
        {
            var prev = events[index - 1];
            var u = (frame - key.T) / (double)key.Ramp;
            gain = prev.Gain + ((key.Gain - prev.Gain) * u);
            if (prev.Pos is not null && key.Pos is not null)
            {
                pos = prev.Pos.Zip(key.Pos, (a, b) => a + ((b - a) * u)).ToArray();
            }
        }

        return new SceneEvent { Id = key.Id, T = frame, Ramp = 0, Gain = gain, Pos = pos };
    }
}

/// <summary>
/// Adapts <see cref="DamfEventStream"/> (which needs to re-read the growing
/// .atmos.metadata file before every cut) to <see cref="ISceneEventSource"/>.
/// </summary>
public sealed class DamfEventSource(DamfEventStream stream, string metadataPath) : ISceneEventSource
{
    public List<SceneEvent> Segment(long from, long to)
    {
        stream.Pump(metadataPath);
        return stream.Segment(from, to);
    }
}

/// <summary>
/// Follows the .atmos.metadata file truehdd is still writing (it flushes after
/// every update) and keeps every element's keyframes in scene frames.
///
/// Later events for an element carry only samplePos and pos, so ramp, gain,
/// active and position persist from its previous event; an inactive element is
/// reported at -144 dB. A film has a few thousand events, so all of them stay
/// in memory and a segment's events are cut out on demand.
/// </summary>
public sealed class DamfEventStream
{
    private readonly long _startFrame;
    private readonly Dictionary<int, List<SceneEvent>> _byElement = new();
    private readonly Dictionary<int, (int Ramp, double Gain, bool Active, double[]? Pos)> _state = new();
    private long _readPosition;
    private string _partialLine = string.Empty;
    private int? _id;
    private long _samplePos;
    private double[]? _pos;
    private (int Ramp, double Gain, bool Active, double[]? Pos) _current;

    /// <param name="startFrame">Scene frame of truehdd's first decoded sample (samplePos 0).</param>
    public DamfEventStream(long startFrame)
    {
        _startFrame = startFrame;
    }

    /// <summary>Reads whatever complete lines have been appended since the last call.</summary>
    public void Pump(string path)
    {
        if (!File.Exists(path))
        {
            return;
        }

        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        stream.Seek(_readPosition, SeekOrigin.Begin);
        using var reader = new StreamReader(stream);
        var text = _partialLine + reader.ReadToEnd();
        _readPosition = stream.Length;
        var lastNewline = text.LastIndexOf('\n');
        _partialLine = lastNewline < 0 ? text : text[(lastNewline + 1)..];
        if (lastNewline < 0)
        {
            return;
        }

        foreach (var raw in text[..lastNewline].Split('\n'))
        {
            Consume(raw.Trim());
        }
    }

    /// <summary>
    /// Events for frames [from, to): first a snapshot of every known element as
    /// it stands at <paramref name="from"/> (no ramp), then the events inside
    /// the range, so a segment decodes on its own. Call once the audio up to
    /// <paramref name="to"/> has been read — truehdd writes an access unit's
    /// metadata before its audio, so everything before then is on disk.
    /// </summary>
    public List<SceneEvent> Segment(long from, long to)
    {
        // The event being parsed is complete if it starts before `to`: its whole
        // block was flushed before that audio was written.
        if (_id is not null && _startFrame + _samplePos < to)
        {
            Flush();
            _id = null;
        }

        return EventTimeline.Segment(_byElement, from, to);
    }

    private void Consume(string line)
    {
        if (line.StartsWith("- ID: ", StringComparison.Ordinal))
        {
            Flush();
            _id = int.Parse(line[6..], CultureInfo.InvariantCulture);
            _current = _state.TryGetValue(_id.Value, out var s) ? s : (0, 0.0, true, null);
            _samplePos = 0;
            _pos = null;
            return;
        }

        var colon = line.IndexOf(':', StringComparison.Ordinal);
        if (_id is null || colon <= 0)
        {
            return;
        }

        var value = line[(colon + 1)..].Trim();
        switch (line[..colon])
        {
            case "samplePos":
                _samplePos = long.Parse(value, CultureInfo.InvariantCulture);
                break;
            case "rampLength":
                _current.Ramp = int.Parse(value, CultureInfo.InvariantCulture);
                break;
            case "gain":
                _current.Gain = value.Contains("inf", StringComparison.Ordinal)
                    ? -144.0
                    : double.Parse(value, CultureInfo.InvariantCulture);
                break;
            case "active":
                _current.Active = value == "true";
                break;
            case "pos":
                _pos = value.Trim('[', ']')
                    .Split(',', StringSplitOptions.TrimEntries)
                    .Select(v => double.Parse(v, CultureInfo.InvariantCulture))
                    .ToArray();
                break;
        }
    }

    private void Flush()
    {
        if (_id is not int id)
        {
            return;
        }

        _current.Pos = _pos ?? _current.Pos;
        _state[id] = _current;
        if (!_byElement.TryGetValue(id, out var events))
        {
            _byElement[id] = events = [];
        }

        events.Add(new SceneEvent
        {
            Id = id,
            T = _startFrame + _samplePos,
            Ramp = _current.Ramp,
            Gain = _current.Active ? _current.Gain : -144.0,
            Pos = _current.Pos
        });
    }
}
