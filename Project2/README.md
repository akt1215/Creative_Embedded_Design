# Misalignment

Misalignment is a two-player maze game controlled through one ESP32 breadboard console. The Pilot steers a rocket-shaped craft with a joystick. The Tuner turns a potentiometer to correct a hidden rotation between the Pilot's input and the craft's movement. The players must reach the target together.

## How to play

The Pilot moves through the maze with the joystick and tells the Tuner how the craft is drifting. The Tuner adjusts the dial until movement matches the Pilot's intention. The hidden rotation changes during each sector, so an alignment that worked earlier may stop working.

A wall collision knocks the craft back, removes 15 HP, and triggers sound, a screen flash, and an LED on the breadboard. Reaching the target repairs 25 HP and starts the next sector. Clear three sectors to finish the run. The external button or joystick switch starts a new run after a win or loss.

## Hardware

| Input or output | ESP32 pin | Role |
| --- | --- | --- |
| Joystick X | GPIO 39 | Pilot's horizontal input |
| Joystick Y | GPIO 32 | Pilot's vertical input |
| Joystick switch | GPIO 33 | New run after the game ends |
| Potentiometer | GPIO 13 | Tuner's angle control |
| External button | GPIO 2 | New run after the game ends |
| LED | GPIO 15 | Wall collision feedback |

The external button uses GPIO 2 in the current firmware.

## How it works

The [ESP32 sketch](Project_2/Project_2.ino) reads the controls and sends a comma-separated packet to Processing at 9,600 baud, approximately every 16 milliseconds.

```text
joystickX,joystickY,potentiometer,resetButton
```

The reset value is active low. Either button can activate it. The [Processing sketch](sketch_261020b/sketch_261020b.pde) normalizes the joystick readings, filters small movements near the center, and maps the potentiometer's reading to a compensation angle from 0 to 360 degrees. The physical dial does not turn through a full circle. Its electrical range represents that angle in the game.

Each frame, Processing rotates the joystick vector by hiddenRotation - calibrationAngle. When the Tuner's angle matches the hidden angle, the Pilot's movement is aligned. Processing generates the maze, handles collisions and scoring, and sends 1 or 0 back to the ESP32 to turn the collision LED on or off.

The current scoring gives the team points for clearing a sector, remaining time, and remaining HP. It then assigns separate Pilot and Tuner points using wall damage and alignment measures. The score split is still being evaluated.

## Build and run

1. Connect the joystick, potentiometer, buttons, and LED to the pins above.
2. Upload [Project_2.ino](Project_2/Project_2.ino) to the TTGO T-Display ESP32.
3. Connect the board to the laptop by USB.
4. Open [sketch_261020b.pde](sketch_261020b/sketch_261020b.pde) in Processing's Java mode. Check the port printed by Serial.list() and set the sketch's current Serial.list()[4] selection to the board's actual port.
5. Run the Processing sketch.

The leaderboard accepts team names and writes a score file, but the current sketch clears that file at startup. Scores therefore do not persist between launches.

[Read the design blog post](https://akitoyamauchi.com/courses/creative-embedded-systems/module-2/)
