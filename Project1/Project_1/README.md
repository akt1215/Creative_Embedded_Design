# Stick Man: Grinding and Burnout

Module 1 generative artwork for COMS 3930X, running on an ESP32 TTGO T-Display. Touch input drives a stick figure through resting, grinding, burnout, and collapse. The piece criticizes a culture that treats constant effort as meaningful progress while overlooking its cost.

## Artistic vision

I wanted to criticize the pressure young people face to keep grinding. Working hard can feel meaningful because it gives us the sense that we are doing something important. But that feeling can make it easy to ignore the cost. My sketch follows a stick figure as that pressure accumulates: it keeps moving, burns out, and eventually collapses. Once burnout sets in, the world around it becomes darker and less vivid. Recovery is possible, but it takes time.

## Design decisions

Touch on the ESP32’s capacitive sensor represents outside pressure. When touched, the figure enters the grinding state and moves faster, even as its energy decreases. That contrast is the center of the piece: visible motion can look like progress while the person doing the work is being depleted.

The energy value carries the effect of pressure forward instead of letting each touch disappear immediately. Below 30% energy, the figure enters burnout. Its pace slows, the scene darkens, and energy recovers more slowly than it does during rest. At zero, the figure collapses against a black sky. Stopping does not instantly restore the capacity lost to overwork.

## Technical challenges

My first challenge was figuring out how to use the ESP32’s capacitive touch sensor. I read the value from GPIO32 with `touchRead()`. At startup, the sketch averages 50 readings to estimate the untouched baseline, then sets the threshold at 75% of that baseline. This gives touch input a role in the piece instead of relying on a button press to select a fixed animation.

The next challenge was updating the visual state from the sensor reading. I added an energy value and used it with touch input to choose among resting, grinding, burnout, and collapse. Each loop updates the energy and state, then changes the figure’s movement and the landscape’s color to match. That connects a live sensor reading to a sequence with lasting consequences.

## Visual documentation

**Media to add:** a GIF or video of the sketch running, plus photos of the device in the installation. These will be added when available.

## Hardware and software

- ESP32 TTGO T-Display
- Arduino IDE with ESP32 board support
- `TFT_eSPI` library configured for the TTGO T-Display

The built-in display uses `TFT_eSPI`. Capacitive touch is read on GPIO32 with `touchRead()`; the onboard action button is GPIO0. No separate display wiring is needed.

## Build and run

1. Install ESP32 board support in Arduino IDE.
2. Install `TFT_eSPI` and enable its `Setup25_TTGO_T_Display.h` configuration for the board’s ST7789 display.
3. Open `Project_1.ino`, select `ESP32 Dev Module` and the serial port, then upload. See [LILYGO’s TTGO T-Display guide](https://github.com/Xinyuan-LilyGO/TTGO-T-Display) and [`TFT_eSPI` display configuration](https://github.com/Bodmer/TFT_eSPI/blob/master/User_Setups/Setup25_TTGO_T_Display.h).
4. Leave the touch input clear during startup calibration. The sketch averages 50 readings, then uses 75% of the baseline as its touch threshold.
5. Touch GPIO32 to trigger grinding. Press the onboard button to recalibrate; after collapse, press it to restart.
