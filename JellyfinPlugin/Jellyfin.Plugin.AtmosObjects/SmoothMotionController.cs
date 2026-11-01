using System.Net.Mime;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// Smooth Motion tracks for 3D titles (see <see cref="SmoothMotionService"/>):
///
///   GET  /SmoothMotion/{itemId}                  state: ready, running (progress 0-1), queued, failed, none or unsupported (reason)
///   POST /SmoothMotion/{itemId}/Analyze          analyse it in the background (202), or 409 with the reason it can't be
///   GET  /SmoothMotion/{itemId}/Chunks/{n}       seconds [n·chunkSeconds, (n+1)·chunkSeconds) as a track of its own
///   GET  /SmoothMotion/{itemId}/Track            the whole track (ranges supported), for a download
/// </summary>
[ApiController]
[Route("SmoothMotion")]
[Authorize]
public class SmoothMotionController : ControllerBase
{
    private readonly SmoothMotionService _smoothMotion;

    public SmoothMotionController(SmoothMotionService smoothMotion)
    {
        _smoothMotion = smoothMotion;
    }

    [HttpGet("{itemId}")]
    [Produces(MediaTypeNames.Application.Json)]
    public ActionResult GetStatus([FromRoute] Guid itemId)
        => new JsonResult(_smoothMotion.GetStatus(itemId), AtmosSceneService.JsonOptions);

    [HttpPost("{itemId}/Analyze")]
    public ActionResult Analyze([FromRoute] Guid itemId)
    {
        if (!_smoothMotion.Enqueue(itemId, out var reason))
        {
            return Conflict(new { reason });
        }

        return new JsonResult(_smoothMotion.GetStatus(itemId), AtmosSceneService.JsonOptions) { StatusCode = StatusCodes.Status202Accepted };
    }

    [HttpGet("{itemId}/Chunks/{index:int}")]
    public async Task<ActionResult> GetChunk([FromRoute] Guid itemId, [FromRoute] int index, CancellationToken ct)
    {
        if (_smoothMotion.GetChunk(itemId, index) is not { } chunk)
        {
            return NotFound();
        }

        var buffer = new byte[chunk.HeaderLength + chunk.Length];
        await using (var file = new FileStream(chunk.Path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, useAsync: true))
        {
            await file.ReadExactlyAsync(buffer.AsMemory(0, chunk.HeaderLength), ct).ConfigureAwait(false);
            file.Position = chunk.Offset;
            await file.ReadExactlyAsync(buffer.AsMemory(chunk.HeaderLength), ct).ConfigureAwait(false);
        }

        // A finished chunk never changes.
        Response.Headers.CacheControl = "private, max-age=86400";
        return File(buffer, "application/octet-stream");
    }

    [HttpGet("{itemId}/Track")]
    public ActionResult GetTrack([FromRoute] Guid itemId)
    {
        var path = _smoothMotion.GetTrackPath(itemId);
        return path is null ? NotFound() : PhysicalFile(path, "application/octet-stream", enableRangeProcessing: true);
    }
}
