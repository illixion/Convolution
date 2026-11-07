using System.Net;
using System.Net.Http.Headers;
using System.Text.Json;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// A Vergence analysis coordinator (<c>vergenced</c>), when the plugin is
/// configured with one: it hands each title to worker machines in 2 s pieces
/// instead of this server analysing it whole (Hypnos
/// <c>docs/plans/analysis-workers.md</c>, step 9). The plugin's own
/// <c>SmoothMotion/</c> routes then pass through to the coordinator's
/// matching routes for any item this server has no finished track for, and
/// the nightly task queues 3D titles there instead of analysing them here.
/// The coordinator serves only whole chunks on these routes.
/// </summary>
public sealed class SmoothMotionCoordinator
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(15) };
    private readonly ILogger<SmoothMotionCoordinator> _logger;

    public SmoothMotionCoordinator(ILogger<SmoothMotionCoordinator> logger)
    {
        _logger = logger;
    }

    private static PluginConfiguration Config => Plugin.Instance?.Configuration ?? new PluginConfiguration();

    /// <summary>Whether a coordinator is configured.</summary>
    public static bool IsConfigured => Uri.TryCreate(Config.AnalysisCoordinatorUrl, UriKind.Absolute, out _)
        && !string.IsNullOrWhiteSpace(Config.AnalysisCoordinatorToken);

    private static HttpRequestMessage Request(HttpMethod method, string path)
    {
        var baseUrl = Config.AnalysisCoordinatorUrl.TrimEnd('/');
        var request = new HttpRequestMessage(method, $"{baseUrl}/{path}");
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", Config.AnalysisCoordinatorToken.Trim());
        return request;
    }

    /// <summary>The coordinator's status for an item, or null when it can't be reached.</summary>
    public async Task<SmoothMotionStatus?> GetStatusAsync(Guid itemId, CancellationToken ct)
    {
        try
        {
            using var response = await Http.SendAsync(Request(HttpMethod.Get, $"SmoothMotion/{itemId:N}"), ct).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
            {
                return null;
            }

            using var json = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false));
            return Status(json.RootElement);
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or JsonException)
        {
            _logger.LogWarning("Smooth Motion: the analysis coordinator didn't answer ({Error})", e.GetType().Name);
            return null;
        }
    }

    /// <summary>Reads the coordinator's status JSON (its numbers may be fractional).</summary>
    public static SmoothMotionStatus Status(JsonElement root)
    {
        static double? Number(JsonElement e, string name) =>
            e.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.Number ? value.GetDouble() : null;
        var state = root.TryGetProperty("state", out var s) ? s.GetString() ?? "none" : "none";
        var reason = root.TryGetProperty("reason", out var r) ? r.GetString() : null;
        return new SmoothMotionStatus(state, reason)
        {
            Progress = Number(root, "progress"),
            ChunkSeconds = Number(root, "chunkSeconds") is { } seconds ? (int)Math.Round(seconds) : null,
            Chunks = Number(root, "chunks") is { } chunks ? (int)chunks : null,
            FrameRate = Number(root, "frameRate"),
            Bytes = Number(root, "bytes") is { } bytes ? (long)bytes : null
        };
    }

    /// <summary>Chunk <paramref name="index"/> when the coordinator has it whole, else null.</summary>
    public async Task<byte[]?> GetChunkAsync(Guid itemId, int index, CancellationToken ct)
    {
        try
        {
            using var response = await Http.SendAsync(Request(HttpMethod.Get, $"SmoothMotion/{itemId:N}/Chunks/{index}"), ct).ConfigureAwait(false);
            return response.StatusCode == HttpStatusCode.OK ? await response.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false) : null;
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            return null;
        }
    }

    /// <summary>Queues an item on the coordinator; the reason when it won't take it.</summary>
    public async Task<(bool Queued, string? Reason)> EnqueueAsync(Guid itemId, CancellationToken ct)
    {
        try
        {
            using var response = await Http.SendAsync(Request(HttpMethod.Post, $"SmoothMotion/{itemId:N}/Analyze"), ct).ConfigureAwait(false);
            if (response.IsSuccessStatusCode)
            {
                return (true, null);
            }

            var body = await response.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
            string? reason = null;
            try
            {
                using var json = JsonDocument.Parse(body);
                reason = json.RootElement.TryGetProperty("reason", out var r) ? r.GetString() : null;
            }
            catch (JsonException)
            {
            }

            return (false, reason ?? $"the analysis coordinator answered {(int)response.StatusCode}");
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            return (false, "the analysis coordinator couldn't be reached");
        }
    }
}
