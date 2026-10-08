using System.Collections.Concurrent;
using System.Globalization;
using System.Security.Cryptography;
using MediaBrowser.Model.Entities;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>An object-audio track a client can choose.</summary>
public sealed record AudioTrack(int Index, string Codec, string? Language, string Title, bool IsDefault);

/// <summary>
/// Audio tracks. A scene is one item's one track: its state, sessions and
/// cache folder are keyed by a scene id derived from the item id and the
/// track's stream index, so switching tracks keeps both decodes. Every
/// client entry point resolves (item, track) to a scene id first; the rest
/// of the service only ever sees scene ids.
///
/// Without a chosen track, the default is the first decodable track in the
/// first language the client lists (its device languages), then
/// <see cref="PluginConfiguration.PreferredAudioLanguage"/>, then the first
/// track. A disc's languages come from <c>mvc3d streams</c>, as ffmpeg's
/// bluray: probe has none.
/// </summary>
public sealed partial class AtmosSceneService
{
    private sealed record Candidate(int Index, AudioCodecKind Codec, string? Language, string Title);

    private readonly ConcurrentDictionary<Guid, (Guid Item, int Stream)> _sceneTargets = new();
    private readonly ConcurrentDictionary<Guid, IReadOnlyList<Candidate>> _candidates = new();

    /// <summary>The item's decodable tracks, the default marked. Null for an unknown item.</summary>
    public IReadOnlyList<AudioTrack>? GetTracks(Guid itemId, string? languages)
    {
        if (Candidates(itemId) is not { } candidates)
        {
            return null;
        }

        var chosen = DefaultTrack(candidates, languages);
        return candidates
            .Select(c => new AudioTrack(c.Index, c.Codec == AudioCodecKind.TrueHd ? "truehd" : "eac3", c.Language, c.Title, c.Index == chosen?.Index))
            .ToList();
    }

    /// <summary>
    /// The scene id for <paramref name="itemId"/>'s track <paramref name="audioStream"/>,
    /// or its default track. Null for an unknown item; an item with no
    /// decodable track gets a scene that reports itself unsupported.
    /// </summary>
    public Guid? ResolveScene(Guid itemId, int? audioStream, string? languages)
    {
        if (Candidates(itemId) is not { } candidates)
        {
            return null;
        }

        var track = audioStream is int requested ? candidates.FirstOrDefault(c => c.Index == requested) : null;
        var index = (track ?? DefaultTrack(candidates, languages))?.Index ?? -1;
        var scene = SceneId(itemId, index);
        if (_sceneTargets.TryAdd(scene, (itemId, index)))
        {
            AdoptLegacyCache(itemId, scene, index, candidates);
        }

        return scene;
    }

    private static Guid SceneId(Guid itemId, int streamIndex)
    {
        var bytes = itemId.ToByteArray().Concat(BitConverter.GetBytes(streamIndex)).ToArray();
        return new Guid(MD5.HashData(bytes));
    }

    private Candidate? DefaultTrack(IReadOnlyList<Candidate> candidates, string? languages)
    {
        var wanted = (languages ?? string.Empty)
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Append(Config.PreferredAudioLanguage)
            .Select(NormalizeLanguage)
            .Where(l => l is not null);
        foreach (var language in wanted)
        {
            if (candidates.FirstOrDefault(c => NormalizeLanguage(c.Language) == language) is { } match)
            {
                return match;
            }
        }

        return candidates.FirstOrDefault();
    }

    /// <summary>
    /// ISO 639-2 in its terminology form ("deu", not "ger"): Jellyfin passes
    /// on what the file says, which may be either, and Apple's locales give
    /// the T form. Two-letter codes are widened.
    /// </summary>
    internal static string? NormalizeLanguage(string? code)
    {
        if (string.IsNullOrWhiteSpace(code))
        {
            return null;
        }

        var c = code.Trim().ToLowerInvariant();
        if (c.Length == 2)
        {
            try
            {
                c = new CultureInfo(c).ThreeLetterISOLanguageName;
            }
            catch (CultureNotFoundException)
            {
                return c;
            }
        }

        return c switch
        {
            "ger" => "deu", "fre" => "fra", "dut" => "nld", "chi" => "zho", "cze" => "ces", "gre" => "ell",
            "per" => "fas", "rum" => "ron", "slo" => "slk", "ice" => "isl", "arm" => "hye", "baq" => "eus",
            "bur" => "mya", "geo" => "kat", "mac" => "mkd", "mao" => "mri", "may" => "msa", "tib" => "bod",
            "wel" => "cym", "alb" => "sqi",
            _ => c
        };
    }

    /// <summary>
    /// TrueHD tracks first (lossless, and the only object audio on a disc),
    /// then E-AC-3 (whether it carries JOC objects is only learnt by decoding
    /// it). Cached per item; a library rescan that changes the streams needs
    /// a server restart to be seen, like the rest of the plugin's item state.
    /// </summary>
    private IReadOnlyList<Candidate>? Candidates(Guid itemId)
    {
        if (_candidates.TryGetValue(itemId, out var cached))
        {
            return cached;
        }

        var item = _libraryManager.GetItemById(itemId);
        if (item is null || string.IsNullOrEmpty(item.Path))
        {
            return null;
        }

        var disc = IsBluray(item);
        var audio = _mediaSourceManager.GetMediaStreams(itemId).Where(s => s.Type == MediaStreamType.Audio).ToList();
        var discLanguages = disc ? DiscTrueHdLanguages(item.Path) : new Dictionary<int, string>();
        var list = new List<Candidate>();
        foreach (var stream in audio.Where(s => string.Equals(s.Codec, "truehd", StringComparison.OrdinalIgnoreCase)))
        {
            var language = discLanguages.GetValueOrDefault(stream.Index) ?? stream.Language;
            list.Add(new Candidate(stream.Index, AudioCodecKind.TrueHd, language, Title(stream, language)));
        }

        // Blu-ray carries objects only in TrueHD, so a disc has no E-AC-3 path.
        if (!disc)
        {
            foreach (var stream in audio.Where(s => string.Equals(s.Codec, "eac3", StringComparison.OrdinalIgnoreCase)))
            {
                list.Add(new Candidate(stream.Index, AudioCodecKind.Eac3, stream.Language, Title(stream, stream.Language)));
            }
        }

        return _candidates.GetOrAdd(itemId, list);
    }

    private static string Title(MediaStream stream, string? language)
    {
        var name = NormalizeLanguage(language) is { } code && TryLanguageName(code) is { } english ? english : null;
        var codec = string.Equals(stream.Codec, "truehd", StringComparison.OrdinalIgnoreCase) ? "TrueHD" : "E-AC-3";
        var channels = stream.Channels is int n ? n switch { 8 => " 7.1", 6 => " 5.1", 2 => " Stereo", _ => $" {n} ch" } : string.Empty;
        var title = string.IsNullOrWhiteSpace(stream.Title) ? null : stream.Title.Trim();
        return string.Join(" · ", new[] { name, title, codec + channels }.Where(s => !string.IsNullOrEmpty(s)));
    }

    private static string? TryLanguageName(string code)
    {
        foreach (var culture in CultureInfo.GetCultures(CultureTypes.NeutralCultures))
        {
            if (culture.ThreeLetterISOLanguageName == code)
            {
                return culture.EnglishName;
            }
        }

        return null;
    }

    /// <summary>
    /// A disc's TrueHD languages by ffmpeg stream index: languages from
    /// <c>mvc3d streams</c> (the playlist's STN table), indexes from probing
    /// the stream mvc3d feeds ffmpeg, matched by PID. Empty when mvc3d isn't
    /// installed or the disc says nothing useful.
    /// </summary>
    private Dictionary<int, string> DiscTrueHdLanguages(string discPath)
    {
        var result = new Dictionary<int, string>();
        if (!File.Exists(Mvc3dPath))
        {
            return result;
        }

        try
        {
            using var list = StartProcess(Mvc3dPath, ["streams", discPath], redirectInput: false);
            var languages = list.StandardOutput.ReadToEnd()
                .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
                .Select(line => line.Split(' '))
                .Where(f => f.Length == 4 && f[0] == "audio" && f[2] == "truehd")
                .ToDictionary(f => Convert.ToInt32(f[1], 16), f => f[3]);
            list.WaitForExit();
            if (languages.Count == 0)
            {
                return result;
            }

            using var feed = DiscFeed.Start(Mvc3dPath, discPath, 0);
            using var probe = StartProcess(_mediaEncoder.ProbePath,
                ["-v", "error", "-i", "pipe:0", "-show_entries", "stream=index,codec_name,id", "-of", "csv=p=0"], redirectInput: true);
            feed.Connect(probe);
            var streams = probe.StandardOutput.ReadToEnd();
            probe.WaitForExit();
            // "1,truehd,0x1100": index first, id last; the AC-3 core shares the PID.
            foreach (var fields in streams.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(l => l.Trim().Split(',')))
            {
                if (fields.Length >= 3 && fields[1] == "truehd" && languages.TryGetValue(Convert.ToInt32(fields[^1], 16), out var language))
                {
                    result[int.Parse(fields[0], CultureInfo.InvariantCulture)] = language;
                }
            }

            _logger.LogInformation("Disc {Path}: TrueHD languages by stream {Languages}",
                Path.GetFileName(discPath), string.Join(", ", result.Select(p => $"{p.Key}={p.Value}")));
        }
        catch (Exception ex) when (ex is IOException or FormatException or InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            _logger.LogWarning(ex, "Could not read the disc's audio languages");
        }

        return result;
    }

    /// <summary>
    /// Caches from before scenes were per track live under the item id, with
    /// the track in <c>track.txt</c> (or, older still, the first TrueHD
    /// track). The matching scene takes the folder over; a cache for a track
    /// no scene can claim is left for that track's scene to adopt later.
    /// </summary>
    private void AdoptLegacyCache(Guid itemId, Guid scene, int streamIndex, IReadOnlyList<Candidate> candidates)
    {
        var legacy = ItemDirectory(itemId);
        if (!Directory.Exists(legacy) || Directory.Exists(ItemDirectory(scene)))
        {
            return;
        }

        var marker = Path.Combine(legacy, "track.txt");
        var track = File.Exists(marker) && int.TryParse(File.ReadAllText(marker).Trim(), out var recorded)
            ? recorded
            : candidates.FirstOrDefault()?.Index ?? -1;
        if (track != streamIndex)
        {
            return;
        }

        try
        {
            Directory.Move(legacy, ItemDirectory(scene));
            _logger.LogInformation("Atmos cache for {ItemId} adopted by its stream {Index} scene", itemId, streamIndex);
        }
        catch (IOException ex)
        {
            _logger.LogWarning(ex, "Could not adopt the Atmos cache for {ItemId}", itemId);
        }
    }
}
