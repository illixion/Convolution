using System.Net.Mime;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// Spatial video (a Vision Pro or iPhone recording, MV-HEVC) streamed as
/// side-by-side HEVC over HLS, converted while it plays (see
/// <see cref="SpatialStreamService"/>):
///
///   GET  /Spatial/{itemId}                        whether it is spatial, and the stream's size
///   GET  /Spatial/{itemId}/main.m3u8              HLS media playlist (pass api_key; it is carried onto every URI)
///   GET  /Spatial/{itemId}/init.mp4               init segment
///   GET  /Spatial/{itemId}/Segments/{n}.m4s       segment n
/// </summary>
[ApiController]
[Route("Spatial")]
[Authorize]
public class SpatialVideoController : ControllerBase
{
    private readonly SpatialStreamService _spatial;

    public SpatialVideoController(SpatialStreamService spatial)
    {
        _spatial = spatial;
    }

    [HttpGet("{itemId}")]
    [Produces(MediaTypeNames.Application.Json)]
    public async Task<ActionResult> GetInfo([FromRoute] Guid itemId, CancellationToken ct)
    {
        var info = await _spatial.GetInfoAsync(itemId, ct).ConfigureAwait(false);
        if (info is null)
        {
            return NotFound();
        }

        return new JsonResult(new
        {
            spatial = info.Spatial,
            reason = info.Reason,
            width = info.Width,
            height = info.Height,
            eyeWidth = info.EyeWidth,
            eyeHeight = info.EyeHeight,
            // Jellyfin's own Video3DFormat names, which clients already map.
            video3DFormat = info.Spatial ? (info.HalfWidth ? "HalfSideBySide" : "FullSideBySide") : null,
            hdr = info.Hdr,
            durationSeconds = info.DurationSeconds,
            frameRate = info.FrameRate,
            segmentSeconds = info.SegmentSeconds,
            segments = info.Segments,
            bitsPerSecond = info.BitsPerSecond,
            playlist = info.Spatial ? $"Spatial/{itemId:N}/main.m3u8" : null
        }, AtmosSceneService.JsonOptions);
    }

    [HttpGet("{itemId}/main.m3u8")]
    public async Task<ActionResult> GetPlaylist([FromRoute] Guid itemId, CancellationToken ct)
    {
        var playlist = await _spatial.GetPlaylistAsync(itemId, Request.QueryString.Value ?? string.Empty, ct).ConfigureAwait(false);
        return playlist is null ? NotFound() : Content(playlist, "application/vnd.apple.mpegurl");
    }

    [HttpGet("{itemId}/init.mp4")]
    public async Task<ActionResult> GetInit([FromRoute] Guid itemId, CancellationToken ct)
    {
        var path = await _spatial.EnsureInitAsync(itemId, ct).ConfigureAwait(false);
        return path is null ? NotFound() : PhysicalFile(path, "video/mp4");
    }

    [HttpGet("{itemId}/Segments/{segment:int}.m4s")]
    public async Task<ActionResult> GetSegment([FromRoute] Guid itemId, [FromRoute] int segment, CancellationToken ct)
    {
        var path = await _spatial.EnsureSegmentAsync(itemId, segment, ct).ConfigureAwait(false);
        return path is null ? NotFound() : PhysicalFile(path, "video/iso.segment");
    }
}
