#include <TFT_eSPI.h>
#include <SPI.h>
#define TOUCH_PIN  32
#define BTN_ACTION 0

TFT_eSPI tft = TFT_eSPI();
int baseline = 75, touchThresh = 50, personX = 20, legStep = 0, mountainOffset = 0;
float energy = 100.0;
String currentState = "Resting";
const int groundY = 105;

void calibration() {
  // Calibrate the capacitive sensor in case pin is touched during boot
  tft.fillScreen(TFT_BLACK);
  tft.setTextDatum(MC_DATUM);
  tft.setTextColor(TFT_YELLOW, TFT_BLACK);
  tft.drawString("Calibrating...", tft.width() / 2, tft.height() / 2, 4);
  long sum = 0;
  for (int i = 0; i < 50; i++) {
    sum += touchRead(TOUCH_PIN);
    delay(10);
  }
  baseline = sum / 50;
  touchThresh = baseline * 0.75;
  tft.fillScreen(TFT_BLACK);
  tft.drawFastHLine(0, groundY + 1, 240, TFT_WHITE);
}

void drawMountains(int offset, uint16_t m1, uint16_t m2, uint16_t cap) {
  int x1 = 60 - offset;
  if (x1 < -60) x1 = x1 + 240;
  tft.fillTriangle(x1, 52, x1 - 50, groundY, x1 + 50, groundY, m1);
  tft.fillTriangle(x1, 52, x1 - 12, 64, x1 + 12, 64, cap);
  int x2 = 180 - offset;
  if (x2 < -60) x2 = x2 + 240;
  tft.fillTriangle(x2, 42, x2 - 60, groundY, x2 + 60, groundY, m2);
  tft.fillTriangle(x2, 42, x2 - 15, 56, x2 + 15, 56, cap);
}

void drawStickman(int x, String state, int step) {
  if (state == "Collapsed") {
    tft.drawCircle(x, groundY - 4, 4, TFT_RED);
    tft.drawLine(x + 4, groundY - 2, x + 25, groundY - 2, TFT_RED);
    return;
  }
  uint16_t color = TFT_WHITE;
  if (state == "Grinding") color = TFT_YELLOW;
  if (state == "Burnout") color = TFT_ORANGE;

  tft.drawCircle(x, groundY - 26, 4, color);
  tft.drawLine(x, groundY - 22, x, groundY - 10, color);
  tft.drawLine(x - 5, groundY - 18, x + 5, groundY - 18, color);

  int s = 6;
  if (step % 2 == 0) s = -6;
  tft.drawLine(x, groundY - 10, x + s, groundY, color);
  tft.drawLine(x, groundY - 10, x - s, groundY, color);
}

void setup() {
  Serial.begin(115200);
  pinMode(BTN_ACTION, INPUT_PULLUP);
  delay(1500);
  tft.init();
  tft.setRotation(1);
  tft.fillScreen(TFT_BLACK);
  calibration();
}

void loop() {
  if (digitalRead(BTN_ACTION) == LOW) {
    if (currentState == "Collapsed") {
      energy = 100.0;
      currentState = "Resting";
      personX = 20;
      tft.fillScreen(TFT_BLACK);
      tft.drawFastHLine(0, groundY + 1, 240, TFT_WHITE);
    } else {
      calibration();
    }
    while (digitalRead(BTN_ACTION) == LOW) delay(10);
  }

  int touchVal = touchRead(TOUCH_PIN);

  if (currentState != "Collapsed") {
    if (touchVal <= touchThresh) {
      if (currentState == "Burnout") {
        energy -= 1.00;
      } else {
        energy -= 0.30;
      }
    } else {
      if (energy < 100.0 && currentState == "Burnout") {
        energy += 0.03;
      } else if (energy < 100.0) {
        energy += 0.10;
      }
    }

    if (energy <= 0.0) {
      energy = 0;
      currentState = "Collapsed";
    } else if (energy <= 30.0) {
      currentState = "Burnout";
    } else if (touchVal <= touchThresh) {
      currentState = "Grinding";
    } else {
      currentState = "Resting";
    }
  }

  // Stage palette: vibrant resting -> desaturated grinding -> charcoal burnout -> void collapsed
  uint16_t skyColor = 0x22F5, m1 = 0x2408, m2 = 0x1B05, cap = TFT_WHITE;
  if (currentState == "Grinding") {
    skyColor = 0x324A; m1 = 0x4226; m2 = 0x3184; cap = 0xCE59;
  } else if (currentState == "Burnout") {
    skyColor = 0x18C3; m1 = 0x2104; m2 = 0x18C2; cap = 0x8410;
  } else if (currentState == "Collapsed") {
    skyColor = TFT_BLACK; m1 = 0x1082; m2 = 0x0841; cap = 0x2104;
  }
  tft.fillRect(0, 26, 240, groundY - 25, skyColor);

  if (currentState == "Grinding") {
    personX = personX + 4;
    mountainOffset = mountainOffset + 3;
  } else if (currentState == "Burnout") {
    personX = personX + 1;
    mountainOffset = mountainOffset + 1;
  } else if (currentState == "Resting") {
    personX = personX + 2;
    mountainOffset = mountainOffset + 1;
  }
  if (mountainOffset >= 240) mountainOffset = mountainOffset - 240;
  if (personX > 220) personX = 10;
  drawMountains(mountainOffset, m1, m2, cap);
  legStep = legStep + 1;
  drawStickman(personX, currentState, legStep);
  tft.drawFastHLine(0, groundY + 1, 240, TFT_WHITE);

  tft.fillRect(0, 0, 240, 25, TFT_BLACK);
  uint16_t textColor = TFT_GREEN;
  if (currentState == "Grinding") textColor = TFT_YELLOW;
  if (currentState == "Burnout") textColor = TFT_ORANGE;
  if (currentState == "Collapsed") textColor = TFT_RED;

  tft.setTextDatum(TL_DATUM);
  tft.setTextColor(textColor, TFT_BLACK);
  tft.drawString(currentState, 10, 6, 2);

  tft.setTextDatum(TR_DATUM);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  tft.drawString("HP: " + String((int)energy) + "%", 230, 6, 2);

  delay(30);
}
