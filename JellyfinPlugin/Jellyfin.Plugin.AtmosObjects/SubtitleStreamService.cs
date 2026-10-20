using System.Diagnostics;
using System.Globalization;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Controller.Library;
using MediaBrowser.Controller.MediaEncoding;
using MediaBrowser.Model.Entities;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// An embedded text subtitle stream as WebVTT, written as ffmpeg reads it,
/// from any point in the file.
///
/// Jellyfin's own <c>Subtitles/{n}/Stream.vtt</c> extracts an embedded
/// stream by reading the whole file before the first byte goes out (every
/// subtitle stream at once), so a TV episode's subtitles waited 15–90 s on a
/// network share and a UHD remux's minutes. Here ffmpeg seeks to the
/// requested time with the container's index and streams the cues as it
/// reaches them: those at the playhead arrive at once, the rest at the speed
/// the file reads. A run from the start that reaches the end is kept, and
/// later requests are served from it whole.
///
/// Timestamps are the file's own (<c>-copyts -start_at_zero</c>), the same
/// timeline Jellyfin's extraction writes, so a client can mix the two.
/// </summary>
public sealed class SubtitleStreamService
{
    private readonly ILibraryManager _libraryManager;
    private readonly IMediaSourceManager _mediaSourceManager;
    private readonly IMediaEncoder _mediaEncoder;
    private readonly IApplicationPaths _paths;
    private readonly ILogger<SubtitleStreamService> _logger;

    public SubtitleStreamService(
        ILibraryManager libraryManager,
        IMediaSourceManager mediaSourceManager,
        IMediaEncoder mediaEncoder,
        IApplicationPaths paths,
        ILogger<SubtitleStreamService> logger)
    {
        _libraryManager = libraryManager;
        _mediaSourceManager = mediaSourceManager;
        _mediaEncoder = mediaEncoder;
        _paths = paths;
        _logger = logger;
    }

    /// <summary>
    /// The file and stream to read, and where a whole extraction is kept.
    /// <paramref name="SubtitleOrdinal"/> is the stream's place among the
    /// file's own subtitle streams (ffmpeg's <c>0:s:N</c>): Jellyfin lists
    /// external files first and numbers the embedded streams after them, so
    /// its <c>Index</c> isn't the container's once an item has a sidecar.
    /// </summary>
    public sealed record Source(string MediaPath, int StreamIndex, int SubtitleOrdinal, string CachePath);

    private static PluginConfiguration Config => Plugin.Instance?.Configuration ?? new PluginConfiguration();

    /// <summary>An embedded text subtitle stream of the item, or null (unknown item, external file, image subtitles).</summary>
    public Source? Resolve(Guid itemId, int streamIndex)
    {
        var item = _libraryManager.GetItemById(itemId);
        if (item is null || string.IsNullOrEmpty(item.Path) || !File.Exists(item.Path))
        {
            return null;
        }

        var embedded = _mediaSourceManager.GetMediaStreams(itemId)
            .Where(s => s.Type == MediaStreamType.Subtitle && !s.IsExternal)
            .OrderBy(s => s.Index)
            .ToList();
        var ordinal = embedded.FindIndex(s => s.Index == streamIndex);
        if (ordinal < 0 || !embedded[ordinal].IsTextSubtitleStream)
        {
            return null;
        }

        var directory = Path.Combine(
            string.IsNullOrWhiteSpace(Config.CacheDirectory) ? Path.Combine(_paths.CachePath, "atmos-objects") : Config.CacheDirectory,
            "v2",
            itemId.ToString("N"),
            "subtitles");
        // Named for the file's version too, so a replaced file isn't served old cues.
        var version = File.GetLastWriteTimeUtc(item.Path).Ticks.ToString(CultureInfo.InvariantCulture);
        return new Source(item.Path, streamIndex, ordinal, Path.Combine(directory, $"{streamIndex}-{version}.vtt"));
    }

    /// <summary>
    /// Streams the cues from <paramref name="startSeconds"/> to the end into
    /// <paramref name="output"/>. <paramref name="begin"/> runs once, just
    /// before the first byte, so a caller can still answer with an error
    /// when ffmpeg fails without writing anything. Returns ffmpeg's error
    /// then, else null.
    /// </summary>
    public async Task<string?> StreamAsync(Source source, double startSeconds, Stream output, Func<Task> begin, CancellationToken ct)
    {
        var args = new List<string> { "-hide_banner", "-loglevel", "error", "-nostdin" };
        if (startSeconds > 0)
        {
            args.AddRange(["-ss", startSeconds.ToString("0.###", CultureInfo.InvariantCulture)]);
        }

        args.AddRange(["-copyts", "-start_at_zero", "-i", source.MediaPath, "-map", $"0:s:{source.SubtitleOrdinal}",
            "-c:s", "webvtt", "-flush_packets", "1", "-f", "webvtt", "pipe:1"]);

        // Only a run over the whole file is worth keeping.
        var keep = startSeconds <= 0;
        var temp = keep ? $"{source.CachePath}.{Guid.NewGuid():N}.part" : null;
        if (temp is not null)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(temp)!);
        }

        var started = Stopwatch.StartNew();
        using var process = StartProcess(_mediaEncoder.EncoderPath, args);
        var errors = process.StandardError.ReadToEndAsync(CancellationToken.None);
        var completed = false;
        var begun = false;
        long written = 0;
        try
        {
            await using var tee = temp is null ? null : new FileStream(temp, FileMode.CreateNew, FileAccess.Write);
            var buffer = new byte[16 * 1024];
            int read;
            while ((read = await process.StandardOutput.BaseStream.ReadAsync(buffer, ct).ConfigureAwait(false)) > 0)
            {
                if (!begun)
                {
                    begun = true;
                    await begin().ConfigureAwait(false);
                    _logger.LogInformation("Subtitle stream {Index} of {Path}: first cues after {Ms} ms from {Start:0.#} s",
                        source.StreamIndex, source.MediaPath, started.ElapsedMilliseconds, startSeconds);
                }

                await output.WriteAsync(buffer.AsMemory(0, read), ct).ConfigureAwait(false);
                await output.FlushAsync(ct).ConfigureAwait(false);
                if (tee is not null)
                {
                    await tee.WriteAsync(buffer.AsMemory(0, read), ct).ConfigureAwait(false);
                }

                written += read;
            }

            await process.WaitForExitAsync(ct).ConfigureAwait(false);
            completed = process.ExitCode == 0;
        }
        catch (OperationCanceledException)
        {
            // The client went away (seeked, or closed the player).
        }
        finally
        {
            if (!process.HasExited)
            {
                try
                {
                    process.Kill(entireProcessTree: true);
                }
                catch (InvalidOperationException)
                {
                }
            }
        }

        if (temp is not null)
        {
            if (completed && written > 0)
            {
                File.Move(temp, source.CachePath, overwrite: true);
                // Tracks kept for earlier versions of the file.
                foreach (var old in Directory.EnumerateFiles(Path.GetDirectoryName(source.CachePath)!, $"{source.StreamIndex}-*.vtt"))
                {
                    if (!string.Equals(old, source.CachePath, StringComparison.Ordinal))
                    {
                        File.Delete(old);
                    }
                }

                _logger.LogInformation("Subtitle stream {Index} of {Path}: whole track kept ({Bytes} bytes, {Seconds:0.#} s)",
                    source.StreamIndex, source.MediaPath, written, started.Elapsed.TotalSeconds);
            }
            else
            {
                File.Delete(temp);
            }
        }

        if (!completed && !begun && !ct.IsCancellationRequested)
        {
            var error = (await errors.ConfigureAwait(false)).Trim();
            _logger.LogWarning("Subtitle stream {Index} of {Path} failed: {Error}", source.StreamIndex, source.MediaPath, error);
            return string.IsNullOrEmpty(error) ? "ffmpeg wrote no subtitles" : error;
        }

        return null;
    }

    private static Process StartProcess(string fileName, IEnumerable<string> args)
    {
        var info = new ProcessStartInfo(fileName)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        foreach (var arg in args)
        {
            info.ArgumentList.Add(arg);
        }

        return Process.Start(info) ?? throw new InvalidOperationException($"Could not start {fileName}");
    }
}
