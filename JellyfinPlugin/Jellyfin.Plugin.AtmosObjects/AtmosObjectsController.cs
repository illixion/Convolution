using System.Net.Mime;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// Client API. A client reads the scene layout (which starts a decode at the
/// requested point if needed), then fetches segments around its playhead;
/// every segment request decodes on demand, so seeking anywhere works without
/// preparing the film first:
///
///   GET  /AtmosObjects/{itemId}/Tracks                   object-audio tracks, the default marked
///   GET  /AtmosObjects/{itemId}                          status
///   POST /AtmosObjects/{itemId}/Prepare                  cache the whole film in the background
///   GET  /AtmosObjects/{itemId}/Scene?startSeconds=T     layout
///   GET  /AtmosObjects/{itemId}/Segments/{n}/Events      snapshot + events for segment n
///   GET  /AtmosObjects/{itemId}/Segments/{n}/{g}         FLAC for segment n, channel group g
///
/// Every audio request takes an optional <c>audioStream</c> (a track's index
/// from Tracks; each track is decoded and cached separately) and
/// <c>languages</c> (ISO 639 codes in the client's order of preference, which
/// pick the default track when no stream is given). A client should read
/// Tracks once and then name its track on every request.
///
/// And the film's video, copied untouched as fragmented MP4 in film time, so
/// the client can render it on the audio's clock:
///
///   GET  /AtmosObjects/{itemId}/Video                    index: segment start times
///   GET  /AtmosObjects/{itemId}/Video/Init               init segment
///   GET  /AtmosObjects/{itemId}/Video/Segments/{n}       segment n (one keyframe interval)
/// </summary>
[ApiController]
[Route("AtmosObjects")]
[Authorize]
public class AtmosObjectsController : ControllerBase
{
    private readonly AtmosSceneService _scenes;
    private readonly VideoSegmentService _video;

    public AtmosObjectsController(AtmosSceneService scenes, VideoSegmentService video)
    {
        _scenes = scenes;
        _video = video;
    }

    [HttpGet("{itemId}")]
    [Produces(MediaTypeNames.Application.Json)]
    public ActionResult<object> GetStatus([FromRoute] Guid itemId, [FromQuery] int? audioStream, [FromQuery] string? languages)
    {
        if (_scenes.ResolveScene(itemId, audioStream, languages) is not Guid scene)
        {
            return NotFound();
        }

        var status = _scenes.GetStatus(scene);
        return new
        {
            state = status.State.ToString().ToLowerInvariant(),
            progressSeconds = status.ProgressSeconds,
            durationSeconds = status.DurationSeconds,
            error = status.Error
        };
    }

    [HttpPost("{itemId}/Prepare")]
    [ProducesResponseType(StatusCodes.Status202Accepted)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public ActionResult Prepare([FromRoute] Guid itemId, [FromQuery] int? audioStream, [FromQuery] string? languages)
        => _scenes.ResolveScene(itemId, audioStream, languages) is Guid scene && _scenes.Prepare(scene) ? Accepted() : NotFound();

    [HttpGet("{itemId}/Tracks")]
    [Produces(MediaTypeNames.Application.Json)]
    public ActionResult GetTracks([FromRoute] Guid itemId, [FromQuery] string? languages)
        => _scenes.GetTracks(itemId, languages) is { } tracks ? new JsonResult(tracks, AtmosSceneService.JsonOptions) : NotFound();

    [HttpGet("{itemId}/Scene")]
    public async Task<ActionResult> GetScene([FromRoute] Guid itemId, [FromQuery] double startSeconds,
                                             [FromQuery] int? audioStream, [FromQuery] string? languages, CancellationToken ct)
    {
        if (_scenes.ResolveScene(itemId, audioStream, languages) is not Guid id)
        {
            return NotFound();
        }

        try
        {
            var scene = await _scenes.GetSceneAsync(id, startSeconds, ct).ConfigureAwait(false);
            return scene is null
                ? UnprocessableEntity(_scenes.GetStatus(id).Error)
                : new JsonResult(scene, AtmosSceneService.JsonOptions);
        }
        catch (FileNotFoundException)
        {
            return NotFound();
        }
        catch (Exception ex) when (ex is TimeoutException or InvalidOperationException)
        {
            return StatusCode(StatusCodes.Status503ServiceUnavailable, ex.Message);
        }
    }

    [HttpGet("{itemId}/Segments/{segment:int}/Events")]
    public async Task<ActionResult> GetSegmentEvents([FromRoute] Guid itemId, [FromRoute] int segment,
                                                     [FromQuery] int? audioStream, [FromQuery] string? languages, CancellationToken ct)
    {
        if (_scenes.ResolveScene(itemId, audioStream, languages) is not Guid scene
            || !await _scenes.EnsureSegmentAsync(scene, segment, ct).ConfigureAwait(false))
        {
            return NotFound();
        }

        var path = _scenes.SegmentEvents(scene, segment);
        return path is null ? NotFound() : PhysicalFile(path, MediaTypeNames.Application.Json);
    }

    [HttpGet("{itemId}/Segments/{segment:int}/{group:int}")]
    public async Task<ActionResult> GetSegment([FromRoute] Guid itemId, [FromRoute] int segment, [FromRoute] int group,
                                               [FromQuery] int? audioStream, [FromQuery] string? languages, CancellationToken ct)
    {
        if (_scenes.ResolveScene(itemId, audioStream, languages) is not Guid scene
            || !await _scenes.EnsureSegmentAsync(scene, segment, ct).ConfigureAwait(false))
        {
            return NotFound();
        }

        var path = _scenes.SegmentFlac(scene, segment, group);
        return path is null ? NotFound() : PhysicalFile(path, "audio/flac");
    }

    [HttpGet("{itemId}/Video")]
    public ActionResult GetVideoIndex([FromRoute] Guid itemId)
    {
        var index = _video.GetIndex(itemId);
        return index is null ? NotFound() : new JsonResult(index, AtmosSceneService.JsonOptions);
    }

    [HttpGet("{itemId}/Video/Init")]
    public async Task<ActionResult> GetVideoInit([FromRoute] Guid itemId, CancellationToken ct)
    {
        var path = await _video.EnsureInitAsync(itemId, ct).ConfigureAwait(false);
        return path is null ? NotFound() : PhysicalFile(path, "video/mp4");
    }

    [HttpGet("{itemId}/Video/Segments/{segment:int}")]
    public async Task<ActionResult> GetVideoSegment([FromRoute] Guid itemId, [FromRoute] int segment, CancellationToken ct)
    {
        var path = await _video.EnsureSegmentAsync(itemId, segment, ct).ConfigureAwait(false);
        return path is null ? NotFound() : PhysicalFile(path, "video/iso.segment");
    }
}
