using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.AspNetCore.Mvc;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// An embedded text subtitle stream as WebVTT, from the playhead on, without
/// waiting for the whole file to be read (see <see cref="SubtitleStreamService"/>):
///
///   GET  /FilmSubtitles/{itemId}/{streamIndex}.vtt?startSeconds=T
///
/// The cues from <c>T</c> (default 0) to the end, written as they are read.
/// A track kept whole from an earlier run comes back whole whatever <c>T</c>
/// is, marked <c>X-Subtitles-Complete: 1</c>. 404 for an unknown item, an
/// external subtitle file (Jellyfin's own route serves those quickly) or
/// image subtitles; 422 when ffmpeg writes nothing.
/// </summary>
[ApiController]
[Route("FilmSubtitles")]
[Authorize]
public class SubtitleStreamController : ControllerBase
{
    private const string VttType = "text/vtt; charset=utf-8";
    private readonly SubtitleStreamService _subtitles;

    public SubtitleStreamController(SubtitleStreamService subtitles)
    {
        _subtitles = subtitles;
    }

    [HttpGet("{itemId}/{streamIndex:int}.vtt")]
    public async Task<ActionResult> GetStream([FromRoute] Guid itemId, [FromRoute] int streamIndex,
                                              [FromQuery] double? startSeconds, CancellationToken ct)
    {
        if (_subtitles.Resolve(itemId, streamIndex) is not { } source)
        {
            return NotFound();
        }

        if (System.IO.File.Exists(source.CachePath))
        {
            Response.Headers["X-Subtitles-Complete"] = "1";
            return PhysicalFile(source.CachePath, VttType);
        }

        // Every write goes out as it is made: the point is the first cues.
        HttpContext.Features.Get<IHttpResponseBodyFeature>()?.DisableBuffering();
        var start = Math.Max(0, startSeconds ?? 0);
        var error = await _subtitles.StreamAsync(source, start, Response.Body, () =>
        {
            Response.StatusCode = StatusCodes.Status200OK;
            Response.ContentType = VttType;
            Response.Headers["X-Subtitles-Complete"] = "0";
            return Response.StartAsync(ct);
        }, ct).ConfigureAwait(false);
        return error is not null && !Response.HasStarted ? UnprocessableEntity(error) : new EmptyResult();
    }
}
