namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>Which AAC encoder an ffmpeg build offers.</summary>
public static class AacEncoders
{
    /// <summary>
    /// From <c>ffmpeg -hide_banner -encoders</c>'s listing: AudioToolbox's
    /// <c>aac_at</c> first (on a Mac server it is the preferred encoder even
    /// where libfdk_aac is built in; the macOS build of Jellyfin 12.2 has no
    /// libfdk_aac, and asking for it failed every AAC bundle), then
    /// libfdk_aac (jellyfin-ffmpeg on Linux), else ffmpeg's own <c>aac</c>,
    /// which every build has.
    /// </summary>
    public static string Pick(string encodersListing)
    {
        static bool Lists(string listing, string name) => listing.Split('\n')
            .Any(line => line.Split(' ', StringSplitOptions.RemoveEmptyEntries) is { Length: >= 2 } parts && parts[1] == name);

        foreach (var name in new[] { "aac_at", "libfdk_aac" })
        {
            if (Lists(encodersListing, name))
            {
                return name;
            }
        }

        return "aac";
    }
}
