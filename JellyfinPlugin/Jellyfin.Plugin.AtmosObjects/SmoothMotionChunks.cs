using System.Buffers.Binary;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// Where each <see cref="ChunkSeconds"/> of an analysis track starts, so a
/// chunk is served as the header plus one byte range. Built once, after the
/// analysis, by reading only the records' headers (Vergence's
/// <c>AnalysisTrack.swift</c> has the format):
///
///   track  = "VGAT" u8(version) u32(header JSON length) header-JSON  record*
///   record = u32(length) u8(kind) u8(eye) u8(encoding) u8(channels) u16(width) u16(height)
///            i64(time value) i64(end value) i32(timescale) ...
///
/// A record belongs to the chunk its time falls in. vergence writes records
/// in time order, so each chunk is one contiguous range; a record whose time
/// goes back stays in the chunk being filled rather than splitting it.
/// </summary>
public sealed class ChunkTable
{
    private const int RecordHeaderBytes = 28;
    private const byte FlowPairKind = 1;

    public int ChunkSeconds { get; set; }

    /// <summary>Bytes of "VGAT", version, length and header JSON: every chunk starts with them.</summary>
    public int HeaderLength { get; set; }

    /// <summary>Per chunk, [offset, length] of its records in the file (length 0 for a stretch without any).</summary>
    public List<long[]> Chunks { get; set; } = [];

    public long Records { get; set; }

    public long Bytes { get; set; }

    /// <summary>The first back-to-back flow pairs' mean rate, as the player's provider reads it.</summary>
    public double? FrameRate { get; set; }

    public static ChunkTable Build(string path, int chunkSeconds)
    {
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16);
        var length = file.Length;
        Span<byte> head = stackalloc byte[RecordHeaderBytes + 4];
        ReadExactly(file, head[..9]);
        if (head[0] != 'V' || head[1] != 'G' || head[2] != 'A' || head[3] != 'T')
        {
            throw new InvalidDataException("not an analysis track");
        }

        var headerLength = checked(9 + (int)BinaryPrimitives.ReadUInt32LittleEndian(head[5..9]));
        var table = new ChunkTable { ChunkSeconds = chunkSeconds, HeaderLength = headerLength, Bytes = length };
        var position = (long)headerLength;
        file.Position = position;
        var chunkStart = position;
        var current = 0;
        double spacingTotal = 0;
        var spacingCount = 0;
        double? previousEnd = null;
        while (position < length)
        {
            if (length - position < head.Length)
            {
                throw new InvalidDataException("truncated record");
            }

            ReadExactly(file, head);
            var recordLength = BinaryPrimitives.ReadUInt32LittleEndian(head[..4]);
            var body = head[4..];
            var timescale = BinaryPrimitives.ReadInt32LittleEndian(body[24..28]);
            if (recordLength < RecordHeaderBytes || timescale <= 0 || position + 4 + recordLength > length)
            {
                throw new InvalidDataException("bad record");
            }

            var time = BinaryPrimitives.ReadInt64LittleEndian(body[8..16]) / (double)timescale;
            var end = BinaryPrimitives.ReadInt64LittleEndian(body[16..24]) / (double)timescale;
            var chunk = (int)Math.Max(0, Math.Floor(time / chunkSeconds));
            while (chunk > current)
            {
                table.Chunks.Add([chunkStart, position - chunkStart]);
                chunkStart = position;
                current++;
            }

            if (body[0] == FlowPairKind && spacingCount < 240)
            {
                var spacing = end - time;
                if (spacing > 0 && (previousEnd is null || Math.Abs(previousEnd.Value - time) < 1e-9))
                {
                    spacingTotal += spacing;
                    spacingCount++;
                }

                previousEnd = end;
            }

            table.Records++;
            position += 4 + recordLength;
            file.Position = position;
        }

        table.Chunks.Add([chunkStart, position - chunkStart]);
        table.FrameRate = spacingCount > 0 ? spacingCount / spacingTotal : null;
        return table;
    }

    private static void ReadExactly(Stream stream, Span<byte> buffer)
    {
        stream.ReadExactly(buffer);
    }
}
