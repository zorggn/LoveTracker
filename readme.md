A module player (for now) written with the LÖVE framework.
----------------------------------------------------------

### Info

- S3M module parsing and playback mostly works.

- Needs a 0.11 löve nightly.

- Requires this font (unless you edit out a line): http://www.fixedsysexcelsior.com/

### Usage

- Drop an .s3m (or s3m. if amiga order) file onto the window.

### TODO

- Eternal code cleanup
- Better timing implementation.
- Understand and fix period/frequency calculation things (compared to OpenMPT, this is horribly "off-key").
- Related to the above, fix E/F/G effects.
- Actually parse the s3m flags field.
- Implement missing effects (H, I, J, K, L, Q, R, all of the S ones, U, V).
- Code better interface
- Allow editing (since this would be a tracker, not just a player...)
- Saving...
- Eventual support for other modules (or not, time will tell.)