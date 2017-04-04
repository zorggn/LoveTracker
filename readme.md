A module player (for now) written with the LÖVE framework.
----------------------------------------------------------

No versions, use the commit history to keep track. :V

### Info

- S3M module parsing and playback works.
- Organya parsing and playback works.

- Needs a 0.11 löve nightly.

### Usage

- Drop an .s3m (s3m.* if amiga order) file onto the window. as3m also works, though without any sound whatsoever.
- Alternatively, drop an .org (org.* works too for reasons) file onto the window.

### ScreamTracker 3 playroutine features

- Buffer-based timing for accurate playback and tracking.
- Support for both 16-bit and stereo samples.
- Channel (voice) matrix view.
- Global stats view.
- Piano keyboard view (shows both note and corrected instrument period values, shows arpeggio state.)
- Pattern view (smooth-scrolling available.)
- All effects supported by ST3 implemented (SFx isn't for obvious reasons, S0x because i'm lazy to add an OALS effect object.)

### Organya playroutine features

- Buffer-based timing for accurate playback and tracking.
- Channel (voice) matrix view.
- Global stats view.
- Org-02 subtype support only.

### TODO

- Eternal code cleanup.
- Code better (graphical) interface.
- Allow editing and saving (since this would be a tracker, not just a player...)

- S3M modules might have their cw/t fields be set to something totally alien to scream tracker 3, so that should be handled.
- Implement a crude AdLib/OPL2 synth so that modules that use that kind of instruments also produce sound.
- Implement Org-03 (and Org-01 if specs can be inferred/gathered) playback.

- Eventual support for other modules (or not, time will tell.)