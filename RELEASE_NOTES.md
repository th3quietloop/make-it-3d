Turns your videos into 3D your Vision Pro plays natively. Runs entirely on
your Mac. No account, no upload, nothing leaves the machine.

## Getting it

Download `MakeIt3D-1.2.1.zip`, unzip, drag to Applications. Signed and notarized by Apple, so
it opens without a warning.

Needs macOS 15 or later on Apple silicon.

## Using it

Drop a video in. The app reads it, finds every cut, and sets the depth for each shot on its
own. Press Convert. When it finishes, send it to the headset and open it in Photos.

Before converting, look at the depth. **Compare eyes** flips between the left and right view,
which makes bad depth obvious in about two seconds on a flat monitor with no glasses.

## What is honest about this release

It works, and it is not finished.

**Some shots show a cut out edge around people.** Where the depth boundary does not land
exactly on a subject's silhouette, the warp tears and you see an outline. It is worst on
people against distinct backgrounds and close to invisible on landscapes, crowds, water, and
anything where depth changes gradually. Turning the strength down to Soft reduces it directly.

**Objects can look internally flat**, like a pop up book, even when they sit at the right
distance from each other.

Both are the signature failure of monocular 2D to 3D conversion. Feathering the disparity
across depth discontinuities is the fix most likely to help and is not implemented yet.
Contributions welcome.

**The Steady depth model is impractical.** It is correct and holds depth perfectly still, but
measured at roughly 0.04 fps against 30 fps for the default. It ships labelled slow, behind a
warning. Do not point it at a film.

**HDR is flattened** to SDR Rec. 709, because the warp renders into 8 bit BGRA.

## How it is verified

Eight automated checks run on every build, including one that reads the finished file with
Apple's own `spatial` command line tool rather than trusting the app's own bookkeeping. Two
of them measure rendered pixels, because three separate bugs in this project looked completely
correct on screen and were only caught by counting.

## Under the hood

Depth Anything V2 Small on the Neural Engine, a Metal mesh warp with disocclusion filling from
earlier frames, and MV-HEVC written through `AVAssetWriterInputTaggedPixelBufferGroupAdaptor`.
Audio is passed through untouched.

Both depth models are Apache 2.0. See [NOTICE.md](NOTICE.md). Everything else is MIT.
