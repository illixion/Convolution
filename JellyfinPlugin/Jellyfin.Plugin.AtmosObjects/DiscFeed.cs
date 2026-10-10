using System.Diagnostics;
using System.Globalization;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// The transport stream of a Blu-ray disc (an ISO or a BDMV folder), fed to
/// ffmpeg through its stdin by Vergence (an MIT Swift Blu-ray reader, not yet published:
/// <c>vergence stream</c>).
/// <para>
/// ffmpeg's own <c>bluray:</c> input reads an ISO through libbluray at a few
/// MB/s and cannot seek in usable time: on servo a cut at one hour into a
/// film took 75 s to start, against about 2 s through Vergence, which jumps to
/// the clip's entry point straight from the disc's EP map. The bytes are the
/// feature playlist's own clips, so ffmpeg sees the same streams in the same
/// order as Jellyfin's <c>bluray:</c> probe (the indexes in MediaStreams hold)
/// and the same timestamps, the clip's own, which <c>bluray:</c> also passes
/// through: the origin probe and the seek arithmetic are unchanged.
/// </para>
/// <para>
/// Vergence seeks in playlist time (0 = the feature's first IN point), so the
/// caller passes the target with the origin subtracted. A feature made of
/// several clips is fed clip after clip, and the timestamps restart with each
/// clip, as they do through <c>bluray:</c>.
/// </para>
/// </summary>
internal sealed class DiscFeed : IDisposable
{
    private readonly Process _mvc3d;
    private readonly Task<string> _errors;

    private DiscFeed(Process mvc3d)
    {
        _mvc3d = mvc3d;
        _errors = mvc3d.StandardError.ReadToEndAsync(CancellationToken.None);
    }

    /// <summary>Starts reading the disc's feature at <paramref name="playlistSeconds"/> (from its entry point at or before).</summary>
    public static DiscFeed Start(string mvc3dPath, string discPath, double playlistSeconds)
    {
        if (!File.Exists(mvc3dPath))
        {
            throw new FileNotFoundException($"vergence not found at {mvc3dPath}; set Mvc3dPath in the plugin configuration.");
        }

        var info = new ProcessStartInfo(mvc3dPath)
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true
        };
        info.ArgumentList.Add("stream");
        info.ArgumentList.Add(discPath);
        if (playlistSeconds > 0)
        {
            info.ArgumentList.Add("--seek");
            info.ArgumentList.Add(playlistSeconds.ToString("F3", CultureInfo.InvariantCulture));
        }

        return new DiscFeed(Process.Start(info) ?? throw new InvalidOperationException($"Could not start {mvc3dPath}"));
    }

    /// <summary>Copies the stream into <paramref name="consumer"/>'s stdin, closing it at the end.</summary>
    public void Connect(Process consumer)
    {
        _ = Task.Run(async () =>
        {
            var input = consumer.StandardInput.BaseStream;
            try
            {
                await _mvc3d.StandardOutput.BaseStream.CopyToAsync(input, 1 << 20).ConfigureAwait(false);
            }
            catch (IOException)
            {
                // The consumer stopped reading (it was killed, or has all it wanted).
            }
            finally
            {
                try
                {
                    input.Close();
                }
                catch (IOException)
                {
                }
            }
        });
    }

    /// <summary>What Vergence reported (where the stream starts, or why it failed).</summary>
    public async Task<string> ErrorsAsync()
    {
        Dispose();
        return (await _errors.ConfigureAwait(false)).Trim();
    }

    public void Dispose()
    {
        try
        {
            if (!_mvc3d.HasExited)
            {
                _mvc3d.Kill();
            }
        }
        catch (InvalidOperationException)
        {
        }
    }
}
