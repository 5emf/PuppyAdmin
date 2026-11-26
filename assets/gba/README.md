# GBA BIOS for the Game Boy Advance window

`cult_bios_v1.bin` is the Cult-of-GBA replacement BIOS (https://github.com/Cult-of-GBA/BIOS, commit 61158c3), written from scratch in ARM assembly by DenSinH and fleroviux. It is MIT-licensed, see `CULT-BIOS-LICENSE.txt`. It is not Nintendo's BIOS.

The script downloads it once. A player who has their own BIOS dump can put it at `PuppyAdmin/gba/gba_bios.bin` (16384 bytes) in the executor folder, and the script uses that one instead. Nintendo's BIOS never goes in this repository.
