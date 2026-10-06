#include <TFT_eSPI.h>
#include <SPI.h>

#define TOUCH_PIN 32 // Header pin (Touch 9)

TFT_eSPI tft = TFT_eSPI();

void setup() {
  Serial.begin(115200);
  delay(1500); // Bypass bootloader ROM text to prevent Serial Plotter freezing

  tft.init();
  tft.setRotation(1); // 240x135 landscape
  tft.fillScreen(TFT_BLACK);
}

void loop() {
  int touchVal = touchRead(TOUCH_PIN);

  Serial.print("Proximity:");
  Serial.println(touchVal);

  // Your calibration, threshold, and TFT rendering logic here

  delay(40); // ~25 Hz
}

void 