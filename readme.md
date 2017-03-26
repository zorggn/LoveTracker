A module player (for now) written with the LÖVE framework.
----------------------------------------------------------

No versions, use the commit history to keep track. :V

### Info

- S3M module parsing and playback mostly works.
- Organya parsing and playback mostly works.

- Needs a 0.11 löve nightly.

- Requires this font (unless you edit out a line): http://www.fixedsysexcelsior.com/

### Usage

- Drop an .s3m (or s3m. if amiga order) file onto the window. as3m also works, though without any sound whatsoever.
- Alternatively, drop an .org file onto the window.

### TODO

- Eternal code cleanup
- <del>Better timing implementation.</del> Works, though low enough buffer sizes may crash Löve after some time...
- Code better interface
- Allow editing and saving (since this would be a tracker, not just a player...)

- <del>Understand and fix period/frequency calculation things (compared to OpenMPT, this is horribly "off-key").</del> Effects now work with the instrument-c4speed-adjusted period values, but the period table is still probably off, since the overall pitch is still lower than OpenMPT, and probably ST3 as well.
- <del>Related to the above, fix E/F/G effects.</del> Done.
- <del>Actually parse the s3m flags field.</del> Done.
- Implement missing effects (H, I, J, K, L, Q, R, <del>all</del> some of the S ones that remain, U, V).
- <del>Adding support for 16bit samples because apparently they're allowed in this format.</del> Done, no Stereo sample support though, but a flag exists for that as well.
- Speaking of, s3m-s might have their cwt fields be set to something totally alien to scream tracker, like mentioned above, so that should be handled as well.

- Eventual support for other modules (or not, time will tell.)