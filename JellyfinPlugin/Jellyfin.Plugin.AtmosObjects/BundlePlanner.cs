namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>What the planner knows about one audible channel of a segment. Levels include the element's metadata gain: they are as heard.</summary>
/// <param name="Channel">The scene channel.</param>
/// <param name="IsLfe">The low-frequency bed, which carries nothing above ~120 Hz.</param>
/// <param name="LevelDb">RMS level in dBFS, metadata gain included.</param>
/// <param name="Position">The element's DAMF room position (x right, y front, z up) at the start of the segment; null for a bed.</param>
internal readonly record struct BundleSource(int Channel, bool IsLfe, float LevelDb, float[]? Position);

/// <summary>One channel the bundle carries, and how it is encoded.</summary>
internal readonly record struct ChannelPlan(int Channel, int Bitrate);

/// <summary>Who gets how many bits, and who is left out.</summary>
internal sealed record BundlePlan(IReadOnlyList<ChannelPlan> Encode, IReadOnlyList<int> Omitted)
{
    public int TotalBitrate => Encode.Sum(c => c.Bitrate);
}

/// <summary>
/// Spreads a bundle's bits over its channels. Every channel is its own mono
/// stream, so a flat rate spends as much on the low-frequency bed and on a
/// whisper nobody can hear over the rest of the mix as on the dialogue. Three
/// things move bits where they are heard:
///
///  - The low-frequency bed carries nothing above ~120 Hz and gets a third of
///    the average (16–32 kbps), and what it doesn't use goes to the others.
///    It is not low-passed first: a filter's delay (1.5 ms for a 160 Hz
///    biquad) would put it out of step with every other channel, for a 1%
///    saving. The encoder's own bandwidth at that rate does the same job.
///  - Dialogue sits in the front-centre element, and the front stage carries
///    most of the rest, so those weigh 1.5 and 1.25. A Dolby Atmos track's
///    only bed is usually the LFE (the speaker channels arrive as objects),
///    so the role comes from the element's position, not its bed name.
///  - Coding noise is heard against the mix, so a channel far below the
///    loudest one needs fewer bits: its weight falls from 1 at 12 dB under
///    the loudest to 0.45 at 48 dB under it (about a kbps per dB at 64 kbps).
///
/// The total is the average times the number of audible channels, or the
/// client's <c>budget</c> if that is less, so a request can say what its link
/// carries however many channels the scene has. With a tight budget the
/// quietest channels go first: floors of half the average (never below 16
/// kbps) hold while they can, and below them channels are left out rather
/// than every channel coded badly.
/// </summary>
internal static class BundlePlanner
{
    public const int MinBitrate = 16_000;
    public const int MaxBitrate = 256_000;
    private const float CenterWeight = 1.5f;
    private const float FrontWeight = 1.25f;

    /// <param name="audible">The channels worth sending, as the segment's events leave them.</param>
    /// <param name="average">Bits per second per audible channel, on average.</param>
    /// <param name="budget">A cap on the segment's bits per second as sent, containers included, or null.</param>
    /// <param name="streamOverhead">What each stream's container costs in bits per second (an M4A's sample tables, about 2.6 kbps for 10 s of AAC), which a budget has to leave room for.</param>
    public static BundlePlan Plan(IReadOnlyList<BundleSource> audible, int average, int? budget, int streamOverhead = 0)
    {
        average = Math.Clamp(average, MinBitrate, MaxBitrate);
        // What `streams` channels may spend on the encoders: the average
        // each, or the budget less the containers' share if that is less.
        long Pool(int streams)
        {
            var total = (long)average * streams;
            if (budget is int cap)
            {
                total = Math.Min(total, cap - ((long)streamOverhead * streams));
            }

            return Math.Max(0, total);
        }

        var encode = new List<ChannelPlan>();
        var omitted = new List<int>();

        // The LFE first: cheap, and what makes an explosion land.
        var lfeRate = Math.Clamp(average / 3 / 1000 * 1000, MinBitrate, 32_000);
        var lfeSpent = 0L;
        foreach (var s in audible.Where(s => s.IsLfe))
        {
            if (Pool(encode.Count + 1) - lfeSpent - lfeRate >= 0)
            {
                encode.Add(new ChannelPlan(s.Channel, lfeRate));
                lfeSpent += lfeRate;
            }
            else
            {
                omitted.Add(s.Channel);
            }
        }

        var rest = audible.Where(s => !s.IsLfe).ToList();
        if (rest.Count == 0)
        {
            return Finish(encode, omitted);
        }

        var reference = rest.Max(s => s.LevelDb);
        var weight = rest.ToDictionary(s => s.Channel, s => RoleWeight(s.Position) * Activity(reference - s.LevelDb));

        // Too little for everyone: the quietest weights go until the rest can
        // each have the minimum.
        var ranked = rest.OrderBy(s => weight[s.Channel]).ThenBy(s => s.LevelDb).ToList();
        while (ranked.Count > 0 && Pool(encode.Count + ranked.Count) - lfeSpent < (long)MinBitrate * ranked.Count)
        {
            omitted.Add(ranked[0].Channel);
            ranked.RemoveAt(0);
        }

        if (ranked.Count > 0)
        {
            var total = Pool(encode.Count + ranked.Count) - lfeSpent;
            var floor = Math.Max(MinBitrate, average / 2);
            if (total < (long)floor * ranked.Count)
            {
                floor = MinBitrate;
            }

            var ceiling = Math.Min(MaxBitrate, average * 2);
            var rates = Distribute(ranked.Select(s => (double)weight[s.Channel]).ToArray(), total, floor, ceiling);
            for (var i = 0; i < ranked.Count; i++)
            {
                // Whole kbps, rounded down: the plan never overspends.
                encode.Add(new ChannelPlan(ranked[i].Channel, (int)(rates[i] / 1000) * 1000));
            }
        }

        return Finish(encode, omitted);
    }

    private static BundlePlan Finish(List<ChannelPlan> encode, List<int> omitted)
    {
        encode.Sort((a, b) => a.Channel.CompareTo(b.Channel));
        omitted.Sort();
        return new BundlePlan(encode, omitted);
    }

    /// <summary>1.5 for a front-centre element (where dialogue is), 1.25 for the rest of the front stage, 1 for anything else.</summary>
    internal static float RoleWeight(float[]? position)
    {
        if (position is not { Length: >= 3 })
        {
            return 1;
        }

        float x = position[0], y = position[1], z = position[2];
        if (z > 0.4f || y < 0.5f)
        {
            return 1;
        }

        if (MathF.Abs(x) <= 0.2f && y >= 0.7f)
        {
            return CenterWeight;
        }

        return MathF.Abs(x) >= 0.5f ? FrontWeight : 1;
    }

    /// <summary>1 within 12 dB of the loudest channel, falling to 0.45 at 48 dB under it.</summary>
    internal static float Activity(float dbBelowLoudest)
        => Math.Clamp(1 - (Math.Max(0, dbBelowLoudest - 12) * 0.0153f), 0.45f, 1f);

    /// <summary>
    /// Shares <paramref name="total"/> in proportion to <paramref name="weights"/>,
    /// no one under <paramref name="floor"/> or over <paramref name="ceiling"/>:
    /// whoever the shares would push past a limit is held there and the
    /// remainder is shared again among the rest.
    /// </summary>
    internal static double[] Distribute(double[] weights, double total, double floor, double ceiling)
    {
        var rates = new double[weights.Length];
        var held = new bool[weights.Length];
        var remaining = total;
        for (var round = 0; round <= weights.Length; round++)
        {
            double sum = 0;
            for (var i = 0; i < weights.Length; i++)
            {
                if (!held[i])
                {
                    sum += weights[i];
                }
            }

            if (sum <= 0)
            {
                break;
            }

            // Hold the ones under their floor first; only when none are,
            // the ones over the ceiling (holding both at once overshoots).
            // Shares are judged against the pool as the round began.
            var pool = remaining;
            var low = false;
            for (var i = 0; i < weights.Length; i++)
            {
                if (!held[i] && pool * weights[i] / sum < floor)
                {
                    rates[i] = floor;
                    held[i] = true;
                    remaining -= floor;
                    low = true;
                }
            }

            if (low)
            {
                continue;
            }

            var high = false;
            for (var i = 0; i < weights.Length; i++)
            {
                if (!held[i] && pool * weights[i] / sum > ceiling)
                {
                    rates[i] = ceiling;
                    held[i] = true;
                    remaining -= ceiling;
                    high = true;
                }
            }

            if (high)
            {
                continue;
            }

            for (var i = 0; i < weights.Length; i++)
            {
                if (!held[i])
                {
                    rates[i] = remaining * weights[i] / sum;
                }
            }

            break;
        }

        return rates;
    }
}
