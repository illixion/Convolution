using MediaBrowser.Common.Configuration;
using MediaBrowser.Common.Plugins;
using MediaBrowser.Controller;
using MediaBrowser.Controller.Plugins;
using MediaBrowser.Model.Serialization;
using Microsoft.Extensions.DependencyInjection;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// Serves the Atmos objects of TrueHD tracks as separate audio stems plus
/// position metadata, so a client can place its own spatial sources instead
/// of relying on a Dolby renderer. Decoding is done by truehdd, an external
/// open-source TrueHD decoder the server operator installs.
/// </summary>
public class Plugin : BasePlugin<PluginConfiguration>
{
    public Plugin(IApplicationPaths applicationPaths, IXmlSerializer xmlSerializer)
        : base(applicationPaths, xmlSerializer)
    {
        Instance = this;
    }

    public static Plugin? Instance { get; private set; }

    // Display name and description only: the dashboard shows these, so they
    // avoid the Dolby/Atmos trademarks. The plugin's identity (Id, assembly
    // name, config file name, AtmosObjects/ routes) is unchanged, so an
    // installed copy keeps its configuration and clients keep working.
    public override string Name => "Convolution Object Audio";

    public override Guid Id => Guid.Parse("030dca02-37ea-4c55-a4d7-726bb00db38a");

    public override string Description =>
        "Extracts the sound objects from a film's object-based soundtrack and serves them as FLAC stems with position metadata, for Convolution's spatial film player.";
}

public class PluginConfiguration : MediaBrowser.Model.Plugins.BasePluginConfiguration
{
    /// <summary>Path to the truehdd binary. Empty means "truehdd" next to the plugin's data folder.</summary>
    public string TruehddPath { get; set; } = string.Empty;

    /// <summary>Where prepared scenes are stored. Empty means &lt;cache&gt;/atmos-objects.</summary>
    public string CacheDirectory { get; set; } = string.Empty;

    /// <summary>Segment length in seconds; every segment is one FLAC file per channel group.</summary>
    public int SegmentSeconds { get; set; } = 10;

    /// <summary>How many segment encoders run at once.</summary>
    public int EncoderParallelism { get; set; } = 4;

    /// <summary>Video segments kept per item before the least recently used are dropped.</summary>
    public int VideoCacheMegabytes { get; set; } = 4096;
}

public class PluginServiceRegistrator : IPluginServiceRegistrator
{
    public void RegisterServices(IServiceCollection serviceCollection, IServerApplicationHost applicationHost)
    {
        serviceCollection.AddSingleton<AtmosSceneService>();
        serviceCollection.AddSingleton<VideoSegmentService>();
    }
}
