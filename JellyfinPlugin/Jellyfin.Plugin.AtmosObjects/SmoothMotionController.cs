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
///
/// With an analysis coordinator configured (<see cref="SmoothMotionCoordinator"/>), an item this server has no
/// finished track for is answered by the coordinator: its status, its whole chunks, and Analyze queues it there.
/// </summary>
[ApiController]
[Route("SmoothMotion")]
[Authorize]
public class SmoothMotionController : ControllerBase
{
    private readonly SmoothMotionService _smoothMotion;
    private readonly SmoothMotionCoordinator _coordinator;

    public SmoothMotionController(SmoothMotionService smoothMotion, SmoothMotionCoordinator coordinator)
    {
        _smoothMotion = smoothMotion;
        _coordinator = coordinator;
    }

    [HttpGet("{itemId}")]
    [Produces(MediaTypeNames.Application.Json)]
    public async Task<ActionResult> GetStatus([FromRoute] Guid itemId, CancellationToken ct)
    {
        var status = _smoothMotion.GetStatus(itemId);
        if (status.State != "ready" && SmoothMotionCoordinator.IsConfigured
            && await _coordinator.GetStatusAsync(itemId, ct).ConfigureAwait(false) is { State: not "none" } remote)
        {
            status = remote;
        }

        return new JsonResult(status, AtmosSceneService.JsonOptions);
    }

    [HttpPost("{itemId}/Analyze")]
    public async Task<ActionResult> Analyze([FromRoute] Guid itemId, CancellationToken ct)
    {
        if (SmoothMotionCoordinator.IsConfigured && _smoothMotion.GetStatus(itemId).State != "ready")
        {
            var (queued, problem) = await _coordinator.EnqueueAsync(itemId, ct).ConfigureAwait(false);
            if (!queued)
            {
                return Conflict(new { reason = problem });
            }

            var remote = await _coordinator.GetStatusAsync(itemId, ct).ConfigureAwait(false) ?? new SmoothMotionStatus("queued", null);
            return new JsonResult(remote, AtmosSceneService.JsonOptions) { StatusCode = StatusCodes.Status202Accepted };
        }

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
            if (SmoothMotionCoordinator.IsConfigured && await _coordinator.GetChunkAsync(itemId, index, ct).ConfigureAwait(false) is { } remote)
            {
                Response.Headers.CacheControl = "private, max-age=86400";
                return File(remote, "application/octet-stream");
            }

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
