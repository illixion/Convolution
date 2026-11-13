using System.Buffers.Binary;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// Reads the single-track Matroska stream ffmpeg writes to a pipe
/// (<c>-c copy -copyts -f matroska</c>) and yields each packet with its
/// timestamp. Only what that stream contains is handled: unknown-size
/// Segment/Cluster, cluster Timestamp, SimpleBlock/BlockGroup without lacing.
/// The timestamps are what pin a mid-film cut to an exact sample — see
/// <see cref="StartSolver"/>.
/// </summary>
public sealed class MatroskaPackets
{
    private const uint EbmlHeader = 0x1A45DFA3;
    private const uint Segment = 0x18538067;
    private const uint Info = 0x1549A966;
    private const uint TimestampScale = 0x2AD7B1;
    private const uint Cluster = 0x1F43B675;
    private const uint ClusterTimestamp = 0xE7;
    private const uint BlockGroup = 0xA0;
    private const uint Block = 0xA1;
    private const uint SimpleBlock = 0xA3;

    private readonly Stream _stream;
    private long _clusterTimestamp;
    private long _timestampScaleNs = 1_000_000;

    public MatroskaPackets(Stream stream)
    {
        _stream = stream;
    }

    /// <summary>Next packet, or null at end of stream. Time is in milliseconds.</summary>
    public async Task<(double TimeMs, byte[] Data)?> ReadAsync(CancellationToken ct)
    {
        while (true)
        {
            var id = await ReadIdAsync(ct).ConfigureAwait(false);
            if (id is null)
            {
                return null;
            }

            var size = await ReadSizeAsync(ct).ConfigureAwait(false);
            switch (id.Value)
            {
                // Masters whose children we want: step inside rather than skip.
                case Segment or Cluster or Info or BlockGroup:
                    continue;
                case TimestampScale:
                    _timestampScaleNs = (long)await ReadUIntAsync(size, ct).ConfigureAwait(false);
                    continue;
                case ClusterTimestamp:
                    _clusterTimestamp = (long)await ReadUIntAsync(size, ct).ConfigureAwait(false);
                    continue;
                case SimpleBlock or Block:
                {
                    var block = new byte[size];
                    await _stream.ReadExactlyAsync(block, ct).ConfigureAwait(false);
                    var trackLength = VintLength(block[0]);
                    var relative = BinaryPrimitives.ReadInt16BigEndian(block.AsSpan(trackLength));
                    var flags = block[trackLength + 2];
                    if ((flags & 0x06) != 0)
                    {
                        throw new InvalidDataException("Laced Matroska blocks are not supported.");
                    }

                    var dataStart = trackLength + 3;
                    var time = (_clusterTimestamp + relative) * (_timestampScaleNs / 1e6);
                    return (time, block[dataStart..]);
                }

                default:
                    if (size < 0)
                    {
                        throw new InvalidDataException($"Unknown-size element 0x{id:X} cannot be skipped.");
                    }

                    await SkipAsync(size, ct).ConfigureAwait(false);
                    continue;
            }
        }
    }

    private static int VintLength(byte first)
    {
        for (var i = 0; i < 8; i++)
        {
            if ((first & (0x80 >> i)) != 0)
            {
                return i + 1;
            }
        }

        throw new InvalidDataException("Invalid EBML variable-length integer.");
    }

    private async Task<uint?> ReadIdAsync(CancellationToken ct)
    {
        var first = new byte[1];
        if (await _stream.ReadAsync(first, ct).ConfigureAwait(false) == 0)
        {
            return null;
        }

        var length = VintLength(first[0]);
        var rest = new byte[length - 1];
        await _stream.ReadExactlyAsync(rest, ct).ConfigureAwait(false);
        uint id = first[0];
        foreach (var b in rest)
        {
            id = (id << 8) | b;
        }

        return id;
    }

    /// <summary>Element size; -1 for "unknown", which live muxing uses for Segment and Cluster.</summary>
    private async Task<long> ReadSizeAsync(CancellationToken ct)
    {
        var first = new byte[1];
        await _stream.ReadExactlyAsync(first, ct).ConfigureAwait(false);
        var length = VintLength(first[0]);
        long value = first[0] & (0xFF >> length);
        var allOnes = value == (0xFF >> length);
        var rest = new byte[length - 1];
        await _stream.ReadExactlyAsync(rest, ct).ConfigureAwait(false);
        foreach (var b in rest)
        {
            value = (value << 8) | b;
            allOnes &= b == 0xFF;
        }

        return allOnes ? -1 : value;
    }

    private async Task<ulong> ReadUIntAsync(long size, CancellationToken ct)
    {
        var bytes = new byte[size];
        await _stream.ReadExactlyAsync(bytes, ct).ConfigureAwait(false);
        ulong value = 0;
        foreach (var b in bytes)
        {
            value = (value << 8) | b;
        }

        return value;
    }

    private async Task SkipAsync(long size, CancellationToken ct)
    {
        var buffer = new byte[Math.Min(size, 1 << 16)];
        while (size > 0)
        {
            var read = await _stream.ReadAsync(buffer.AsMemory(0, (int)Math.Min(size, buffer.Length)), ct).ConfigureAwait(false);
            if (read == 0)
            {
                throw new EndOfStreamException();
            }

            size -= read;
        }
    }
}

/// <summary>
/// Finds the exact scene frame of the first access unit a cut starts at.
///
/// Every TrueHD access unit carries a fixed number of samples (40 at 48 kHz),
/// and a container timestamp rounded to the millisecond. Each packet therefore
/// bounds the start to a window one millisecond wide; intersecting a few
/// hundred consecutive windows, knowing how many samples separate the packets,
/// leaves exactly one frame on the access-unit grid. Verified against a full
/// decode on a UHD Blu-ray remux: zero-sample error at cuts across the film.
///
/// Not every remux stamps its TrueHD packets that exactly. On The Wild Robot
/// the timestamps drift from the sample count by more than half a
/// millisecond and snap back about every 1,024 packets, as if interpolated
/// between the disc's own timestamps. A run straddling a snap has no
/// consistent frame (<see cref="IsConsistent"/>); the feeder then starts a
/// fresh run at the next restart point, which solves.
/// </summary>
public sealed class StartSolver
{
    private readonly double _samplesPerMs;
    private readonly int _samplesPerAu;
    private readonly long _origin;
    private readonly double _half;
    private long _samplesBefore;
    private long _lo = long.MinValue;
    private long _hi = long.MaxValue;

    /// <param name="sampleRate">Stream sample rate.</param>
    /// <param name="samplesPerAu">Samples per access unit.</param>
    /// <param name="originMs">Timestamp of the stream's first access unit, which is scene frame 0.</param>
    /// <param name="toleranceMs">
    /// How far a packet's timestamp may be from its true time. A tick's rounding is half a millisecond; a
    /// file cut by ffmpeg without <c>-copyts</c> has its times rounded twice and strays up to a millisecond
    /// (measured on a DTS track). Only an access unit far longer than twice this pins a frame: DTS's 512
    /// samples take 1.5 ms, TrueHD's 40 can't.
    /// </param>
    public StartSolver(int sampleRate, int samplesPerAu, double originMs, double toleranceMs = 0.5)
    {
        _samplesPerMs = sampleRate / 1000.0;
        _samplesPerAu = samplesPerAu;
        _origin = (long)Math.Round(originMs * _samplesPerMs);
        _half = toleranceMs * _samplesPerMs;
    }

    public int Packets { get; private set; }

    /// <summary>False once no frame fits every packet's window.</summary>
    public bool IsConsistent => _lo <= _hi;

    /// <summary>Adds the next packet (from the first kept access unit on).</summary>
    public void Add(double timeMs, int accessUnits)
    {
        var center = (timeMs * _samplesPerMs) - _origin - _samplesBefore;
        _lo = Math.Max(_lo, (long)Math.Ceiling(center - _half));
        _hi = Math.Min(_hi, (long)Math.Floor(center + _half));
        _samplesBefore += (long)accessUnits * _samplesPerAu;
        Packets++;
    }

    /// <summary>The start frame once exactly one grid frame fits, else null.</summary>
    public long? Solve()
    {
        if (_lo > _hi)
        {
            throw new InvalidDataException("Packet timestamps are inconsistent with a fixed access-unit length.");
        }

        var first = (long)Math.Ceiling(_lo / (double)_samplesPerAu) * _samplesPerAu;
        return first + _samplesPerAu > _hi && first <= _hi ? first : null;
    }
}
