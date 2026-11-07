using MediaBrowser.Model.Tasks;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>
/// Analyses every 3D title that has no Smooth Motion track yet, one after
/// another (about 3.5 hours a film on an M1). Runs nightly; cancelling it
/// stops the film being analysed, which starts over next time. A title
/// whose analysis failed is skipped until its failed.txt is removed or a
/// client asks for it again. With an analysis coordinator configured, it
/// queues the titles there instead (<see cref="SmoothMotionCoordinator"/>).
/// </summary>
public class SmoothMotionTask : IScheduledTask
{
    private readonly SmoothMotionService _smoothMotion;
    private readonly SmoothMotionCoordinator _coordinator;
    private readonly ILogger<SmoothMotionTask> _logger;

    public SmoothMotionTask(SmoothMotionService smoothMotion, SmoothMotionCoordinator coordinator, ILogger<SmoothMotionTask> logger)
    {
        _smoothMotion = smoothMotion;
        _coordinator = coordinator;
        _logger = logger;
    }

    public string Name => "Prepare Smooth Motion for 3D titles";

    public string Key => "ConvolutionSmoothMotion";

    public string Description => "Analyses the motion in each 3D film and episode once, so Convolution can show them at double the frame rate.";

    public string Category => "Convolution";

    public async Task ExecuteAsync(IProgress<double> progress, CancellationToken cancellationToken)
    {
        if (!(Plugin.Instance?.Configuration.SmoothMotion ?? false))
        {
            return;
        }

        var items = _smoothMotion.Candidates();
        if (SmoothMotionCoordinator.IsConfigured)
        {
            // The coordinator's workers do the analysis; this only queues the titles there, as backfill.
            var queued = 0;
            for (var i = 0; i < items.Count; i++)
            {
                progress.Report(100.0 * i / items.Count);
                var (ok, reason) = await _coordinator.EnqueueAsync(items[i].Id, cancellationToken).ConfigureAwait(false);
                if (ok)
                {
                    queued++;
                }
                else
                {
                    _logger.LogInformation("Smooth Motion: the analysis coordinator didn't take {ItemId}: {Reason}", items[i].Id, reason);
                }
            }

            _logger.LogInformation("Smooth Motion: {Queued} of {Count} 3D titles queued on the analysis coordinator", queued, items.Count);
            progress.Report(100);
            return;
        }

        _logger.LogInformation("Smooth Motion: {Count} 3D titles to analyse", items.Count);
        for (var i = 0; i < items.Count; i++)
        {
            progress.Report(100.0 * i / items.Count);
            await _smoothMotion.AnalyzeAsync(items[i].Id, cancellationToken).ConfigureAwait(false);
        }

        progress.Report(100);
    }

    public IEnumerable<TaskTriggerInfo> GetDefaultTriggers() =>
    [
        new TaskTriggerInfo { Type = TaskTriggerInfoType.DailyTrigger, TimeOfDayTicks = TimeSpan.FromHours(1).Ticks }
    ];
}
