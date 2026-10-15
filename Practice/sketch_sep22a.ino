/**************************************************************************
  Draws concentric rounded rectangles using drawSmoothRoundRect
 **************************************************************************/
#include <TFT_eSPI.h>
#include <SPI.h>

TFT_eSPI tft = TFT_eSPI();
uint16_t color;
long randomInt;

void setup() {
  tft.init();
  tft.setRotation(1);  // 1 = landscape, 2 = portrait
}

void loop() {
  // randomInt = random(2);

  // switch (randomInt) {
  //   case 0:
  //     color = TFT_PURPLE;
  //     break;

  //   case 1:
  //     color =  TFT_GREEN;
  //     break;

  //   default:
  //     color = TFT_BLACK;
  //     break;
  // }
  concentricRects();
}

void concentricRects() {
  tft.fillScreen(TFT_BLACK);

  for (int16_t x = 0; x < tft.width(); x += 10) {
    randomInt = random(5);
    switch (randomInt) {
      case 0:
        color = TFT_PURPLE;
        break;

      case 1:
        color = TFT_GREEN;
        break;

      case 2:
        color = TFT_RED;
        break;

      case 3:
        color = TFT_ORANGE;
        break;

      case 4:
        color = TFT_BLUE;
        break;

      default:
        color = TFT_BLACK;
        break;
    }
    tft.drawSmoothRoundRect(tft.width() / 2 - x / 2, tft.height() / 2 - x / 2, 1, 1, x, x, color);
    // toggle below to compare how smoothRoundRect compares to regular rect.  drawSmooth functions handle anti-aliasing
    // tft.drawRect(tft.width() / 2 - x / 2, tft.height() / 2 - x / 2 , x, x, color);
    delay(500);
  }
}