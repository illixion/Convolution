using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Http.Features;
using Microsoft.AspNetCore.Mvc;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// An embedded subtitle stream from the playhead on, without waiting for the
/// whole file to be read (see <see cref="SubtitleStreamService"/>):
///
///   GET  /FilmSubtitles/{itemId}/{streamIndex}.vtt?startSeconds=T   a text stream as WebVTT
///   GET  /FilmSubtitles/{itemId}/{streamIndex}.sup?startSeconds=T   a PGS stream as a .sup file
///
/// The cues from <c>T</c> (default 0) to the end, written as they are read.
/// A track kept whole from an earlier run comes back whole whatever <c>T</c>
/// is, marked <c>X-Subtitles-Complete: 1</c>. 404 for an unknown item, an
/// external subtitle file (Jellyfin's own route serves those quickly) or a
/// stream of the other kind (and VobSub/DVB, which neither serves); 422 when
/// ffmpeg writes nothing.
/// </summary>
[ApiController]
[Route("FilmSubtitles")]
[Authorize]
public class SubtitleStreamController : ControllerBase
{
    private const string VttType = "text/vtt; charset=utf-8";
    private const string SupType = "application/octet-stream";
    private readonly SubtitleStreamService _subtitles;

    public SubtitleStreamController(SubtitleStreamService subtitles)
    {
        _subtitles = subtitles;
    }

    [HttpGet("{itemId}/{streamIndex:int}.vtt")]
    public Task<ActionResult> GetStream([FromRoute] Guid itemId, [FromRoute] int streamIndex,
                                        [FromQuery] double? startSeconds, CancellationToken ct) =>
        Serve(itemId, streamIndex, SubtitleStreamService.SubtitleFormat.WebVtt, VttType, startSeconds, ct);

    [HttpGet("{itemId}/{streamIndex:int}.sup")]
    public Task<ActionResult> GetPgsStream([FromRoute] Guid itemId, [FromRoute] int streamIndex,
                                           [FromQuery] double? startSeconds, CancellationToken ct) =>
        Serve(itemId, streamIndex, SubtitleStreamService.SubtitleFormat.Sup, SupType, startSeconds, ct);

    private async Task<ActionResult> Serve(Guid itemId, int streamIndex, SubtitleStreamService.SubtitleFormat format,
                                           string contentType, double? startSeconds, CancellationToken ct)
    {
        if (_subtitles.Resolve(itemId, streamIndex, format) is not { } source)
        {
            return NotFound();
        }

        if (System.IO.File.Exists(source.CachePath))
        {
            Response.Headers["X-Subtitles-Complete"] = "1";
            return PhysicalFile(source.CachePath, contentType);
        }

        // Every write goes out as it is made: the point is the first cues.
        HttpContext.Features.Get<IHttpResponseBodyFeature>()?.DisableBuffering();
        var start = Math.Max(0, startSeconds ?? 0);
        var error = await _subtitles.StreamAsync(source, start, Response.Body, () =>
        {
            Response.StatusCode = StatusCodes.Status200OK;
            Response.ContentType = contentType;
            Response.Headers["X-Subtitles-Complete"] = "0";
            return Response.StartAsync(ct);
        }, ct).ConfigureAwait(false);
        return error is not null && !Response.HasStarted ? UnprocessableEntity(error) : new EmptyResult();
    }
}
