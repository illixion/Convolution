namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// Just enough DTS framing for cutting a DTS:X track mid-film: whether a
/// packet starts at a frame (core sync 0x7FFE8001, or an extension substream
/// 0x64582025 for a stream without a core), how many frames a packet holds,
/// and how many samples a frame is. The sample count comes from the core
/// header (NBLKS); a DTS-HD MA frame's lossless part covers the same span at
/// 48 kHz, the only rate harletty decodes DTS:X at.
/// </summary>
public static class DtsFrames
{
    private const uint CoreSync = 0x7FFE8001;
    private const uint SubstreamSync = 0x64582025;

    private static uint Word(ReadOnlySpan<byte> data, int at) =>
        at + 4 <= data.Length ? (uint)((data[at] << 24) | (data[at + 1] << 16) | (data[at + 2] << 8) | data[at + 3]) : 0;

    /// <summary>A packet that starts at a frame.</summary>
    public static bool StartsAtFrame(ReadOnlySpan<byte> data) => Word(data, 0) is CoreSync or SubstreamSync;

    /// <summary>Samples in the packet's first frame, from its core header; 512 without one.</summary>
    public static int SamplesPerFrame(ReadOnlySpan<byte> data)
    {
        if (Word(data, 0) != CoreSync || data.Length < 8)
        {
            return 512;
        }

        // FTYPE 1, SHORT 5, CPF 1, NBLKS 7: NBLKS + 1 blocks of 32 samples.
        var blocks = ((data[4] & 0x01) << 6) | (data[5] >> 2);
        return (blocks + 1) * 32;
    }

    /// <summary>Frames in a packet: each a core frame and the extension substreams after it.</summary>
    public static int Count(ReadOnlySpan<byte> data)
    {
        int count = 0, p = 0;
        while (p + 12 <= data.Length)
        {
            var word = Word(data, p);
            if (word == CoreSync)
            {
                // FSIZE (14 bits after NBLKS): the core frame's bytes, less one.
                var size = (((data[p + 5] & 0x03) << 12) | (data[p + 6] << 4) | (data[p + 7] >> 4)) + 1;
                if (size < 96)
                {
                    break;
                }

                count++;
                p += size;
                while (Word(data, p) == SubstreamSync && SubstreamSize(data[p..]) is int extra and > 0)
                {
                    p += extra;
                }
            }
            else if (word == SubstreamSync && SubstreamSize(data[p..]) is int size and > 0)
            {
                count++;
                p += size;
            }
            else
            {
                break;
            }
        }

        return Math.Max(count, 1);
    }

    /// <summary>An extension substream's size in bytes (its nuExtSSFsize, plus one).</summary>
    private static int? SubstreamSize(ReadOnlySpan<byte> data)
    {
        if (data.Length < 12)
        {
            return null;
        }

        // After the sync: UserDefinedBits 8, nExtSSIndex 2, bHeaderSizeType 1,
        // then header size and frame size of 8 and 16 bits, or 12 and 20.
        var bits = new BitReader(data[4..]);
        bits.Skip(8 + 2);
        var wide = bits.Read(1) == 1;
        bits.Skip(wide ? 12 : 8);
        return (int)bits.Read(wide ? 20 : 16) + 1;
    }

    private ref struct BitReader(ReadOnlySpan<byte> data)
    {
        private readonly ReadOnlySpan<byte> _data = data;
        private int _bit;

        public void Skip(int count) => _bit += count;

        public uint Read(int count)
        {
            uint value = 0;
            for (var i = 0; i < count; i++, _bit++)
            {
                var b = _bit >> 3;
                value = (value << 1) | (uint)(b < _data.Length ? (_data[b] >> (7 - (_bit & 7))) & 1 : 0);
            }

            return value;
        }
    }
}
