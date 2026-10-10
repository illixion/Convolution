namespace Jellyfin.Plugin.AtmosObjects;

/// <summary>What <c>vergence sbs --info</c> says about an item, plus where it was read from.</summary>
public sealed class SpatialInfo
{
    public bool Spatial { get; set; }
    public int Width { get; set; }
    public int Height { get; set; }
    public int EyeWidth { get; set; }
    public int EyeHeight { get; set; }
    public bool HalfWidth { get; set; }
    public double DurationSeconds { get; set; }
    public double FrameRate { get; set; }
    public double SegmentSeconds { get; set; }
    public int Segments { get; set; }
    public long BitsPerSecond { get; set; }
    public bool Hdr { get; set; }
    /// <summary>Why the item can't be streamed side by side, when it can't.</summary>
    public string? Reason { get; set; }
    /// <summary>The source file's size and modification time when this was read; a change invalidates the cache.</summary>
    public long SourceBytes { get; set; }
    public long SourceTicks { get; set; }
}
