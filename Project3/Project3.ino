/*
  Module 3: Button Rhythm Game for the ESP32 LILYGO T-Display
  Hit the bubbles as they cross the red target line.  The boards broadcast
  their button presses to each other using ESP-NOW.

  Supports 2-3 players (must modify TEAM_ID and PLAYER_ID). 
  - TEAM_ID:   should match for all members on a team
  - PLAYER_ID: unique for each member on a team (0, 1, or 2) 
*/
#include <WiFi.h>
#include <esp_now.h>
#include <TFT_eSPI.h>
#include <cmath>
#include "bg.h"

#define TEAM_ID       3      // Must match for all teammates
#define PLAYER_ID     1      // Unique per board: 0, 1, or 2
#define MAX_PLAYERS   3
#define MAX_NOTES     16
#define BUTTON_A      0      // Left button
#define BUTTON_B      35     // Right button (hardware pull-up on board)
#define HEARTBEAT_MS  250

uint8_t broadcastAddress[] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};

TFT_eSPI tft = TFT_eSPI();
TFT_eSprite spr = TFT_eSprite(&tft); // active render sprite buffer
TFT_eSprite bgSprite = TFT_eSprite(&tft); // sprite the (static) background

// Shared Game State
int sharedScore                 = 0; 
int last_sharedScore            = 0; 
int lastRating                  = 3; // 0: Miss, 1: Bad, 2: Good, 3: Perfect
int lastPlayerId                = PLAYER_ID;
bool seen[MAX_PLAYERS]          = {false, false, false};

volatile bool resetRequested    = false;
bool gameOver                   = false;
uint32_t gameOverAt             = 0;
uint32_t roundStartTime         = 0;
uint32_t lastHeartbeat          = 0;
bool needsRedraw                = true;

bool lastA = HIGH, lastB = HIGH;
uint32_t lastPressTime = 0;

// Bubbles
uint32_t lastBubbleUpdate = 0;
bool noteDone[MAX_NOTES] = {false};
float bubbleY = 60.0f;
float bubbleTargetX = 200.0f;
const float approachDuration = 1000.0f; // 1 second travel window

const uint16_t playerColors[MAX_PLAYERS] = {TFT_CYAN, TFT_ORANGE, TFT_GREEN};
const char* ratingLabels[] = {"MISS (-100)", "BAD (-10)", "GOOD (+20)", "PERFECT! (+200)"};
uint32_t lastScoreTime = 0;
int localBarRating = -1; // Local rating used to color the target bar
const uint32_t feedbackDuration = 800; // How long the score message stays visible (ms)

// Timing Windows (milliseconds)
const float perfectDelta = 45.0f;
const float goodDelta    = 120.0f;
const float badDelta     = 240.0f;

struct TimeList {
  int arraySize;
  float timing[MAX_NOTES];
};

// Target beat offsets relative to round start (in milliseconds, ~100 BPM interlocking tracks)
TimeList correctTimes[MAX_PLAYERS] = {
  // Player 0: syncopated tresillo groove + double-tap break
  {13, {1500.0f, 2400.0f, 3300.0f, 3900.0f, 4500.0f, 5400.0f, 6000.0f, 6300.0f, 7500.0f, 8400.0f, 9300.0f, 9900.0f, 10500.0f}},
  // Player 1: off-beat call-and-response + double-tap fills
  {13, {1800.0f, 2700.0f, 3000.0f, 3900.0f, 4800.0f, 5100.0f, 6300.0f, 6900.0f, 7200.0f, 8100.0f, 8700.0f, 9600.0f, 10500.0f}},
  // Player 2: gallop bursts + cross-rhythm + accelerating finale
  {16, {1500.0f, 2100.0f, 2450.0f, 2800.0f, 3900.0f, 4250.0f, 5100.0f, 5700.0f, 6300.0f, 7050.0f, 7800.0f, 8550.0f, 9300.0f, 9750.0f, 10125.0f, 10500.0f}}
};

// Packet format
typedef struct {
  uint8_t  teamId;
  uint8_t  playerId;
  uint8_t  isReset;
  uint8_t  isGameOver;
  int16_t  sharedScore;
  uint8_t  rating;
} Message;

// Find the latest target time across all players' tracks
float getLatestBeatTime() {
  float maxTime = 0.0f;
  for (int p = 0; p < MAX_PLAYERS; p++) {
    int count = correctTimes[p].arraySize;
    if (count > 0) {
      float last = correctTimes[p].timing[count - 1];
      if (last > maxTime) maxTime = last;
    }
  }
  return maxTime;
}

void onReceive(const esp_now_recv_info_t *info, const uint8_t *data, int len) {
  if (len != sizeof(Message)) return;

  Message msg;
  memcpy(&msg, data, sizeof(msg));
  if (msg.teamId != TEAM_ID) return;
  if (msg.playerId >= MAX_PLAYERS) return;
  if (msg.playerId == PLAYER_ID) return;

  if (msg.isReset) {
    resetRequested = true;
  } else {
    sharedScore  = msg.sharedScore;
    lastRating   = msg.rating;
    lastPlayerId = msg.playerId;
    seen[msg.playerId] = true;

    if (msg.isGameOver && !gameOver) {
      gameOver = true;
      gameOverAt = millis();
    }
    needsRedraw = true;
  }
}

void setupEspNow() {
  WiFi.mode(WIFI_STA);
  if (esp_now_init() != ESP_OK) {
    tft.fillScreen(TFT_BLACK);
    tft.setTextColor(TFT_RED);
    tft.drawString("ESP-NOW Error", 10, 60, 2);
    while (true) delay(1000);
  }
  esp_now_register_recv_cb(onReceive);

  esp_now_peer_info_t peer = {};
  memcpy(peer.peer_addr, broadcastAddress, 6);
  peer.channel = 0;
  peer.encrypt = false;
  esp_now_add_peer(&peer);
}

void sendState(bool reset = false) {
  Message msg;
  msg.teamId      = TEAM_ID;
  msg.playerId    = PLAYER_ID;
  msg.isReset     = reset ? 1 : 0;
  msg.isGameOver  = gameOver ? 1 : 0;
  msg.rating      = (uint8_t)lastRating;
  msg.sharedScore = (int16_t)sharedScore;
  esp_now_send(broadcastAddress, (uint8_t *)&msg, sizeof(msg));
}

void startNewRound() {
  sharedScore = 0;
  lastRating = 3; // gold
  lastPlayerId = PLAYER_ID;
  gameOver = false;
  roundStartTime = millis();
  seen[PLAYER_ID] = true;

  for (int i = 0; i < MAX_NOTES; i++) {
    noteDone[i] = false;
  }
  lastScoreTime = 0;
  localBarRating = -1;
  needsRedraw = true;
}

bool buttonPressed(uint8_t pin, bool &last) {
  bool now = digitalRead(pin);
  bool pressed = (last == HIGH && now == LOW);
  last = now;
  return pressed;
}

int findTargetNoteIndex(const float times[], const bool done[], int arraySize, float pressedTime) {
  for (int i = 0; i < arraySize; i++) {
    if (done[i]) continue;
    if (fabsf(times[i] - pressedTime) <= badDelta) {
      return i;
    }
  }
  return -1;
}

uint16_t getRatingColor(int rating) {
  if (rating == 3) return TFT_GOLD;   // Perfect
  if (rating == 2) return TFT_GREEN;  // Good
  if (rating == 1) return TFT_ORANGE; // Bad
  if (rating == 0) return TFT_RED;    // Miss
  return TFT_WHITE;                   // Idle
}

void drawTargetBar() {
  bool showFeedback = (lastScoreTime > 0) && (millis() - lastScoreTime < feedbackDuration);
  uint16_t barColor = showFeedback ? getRatingColor(localBarRating) : TFT_WHITE;
  spr.fillRect((int)bubbleTargetX - 1, 0, 3, 118, barColor);
}

void drawScene(float timeElapsed) {
  bgSprite.pushToSprite(&spr, 0, 0);
  drawTargetBar();

  if (!gameOver && timeElapsed >= 0.0f) {
    int totalBubbles = correctTimes[PLAYER_ID].arraySize;
    for (int i = 0; i < totalBubbles; i++) {
      if (noteDone[i]) continue;

      float targetTime = correctTimes[PLAYER_ID].timing[i];
      if (timeElapsed > targetTime + badDelta) {
        noteDone[i] = true;
        continue;
      }

      float spawnTime = targetTime - approachDuration;
      if (timeElapsed < spawnTime) continue;

      float x = ((timeElapsed - spawnTime) / approachDuration) * bubbleTargetX;
      if (x <= 240.0f) {
        spr.fillCircle((int)x, (int)bubbleY, 10, playerColors[PLAYER_ID]);
        spr.drawCircle((int)x, (int)bubbleY, 10, TFT_WHITE);
      }
    }
  }

  // Score message text
  if (lastScoreTime > 0 && millis() - lastScoreTime < feedbackDuration) {
    spr.setTextDatum(MC_DATUM);
    uint16_t ratingColor = getRatingColor(lastRating);
    spr.setTextColor(ratingColor, TFT_BLACK);
    spr.drawString(ratingLabels[lastRating], 120, 30, 2); // Display centered near top
    spr.setTextDatum(TL_DATUM);
  }

  // Draw Score footer to sprite
  spr.fillRect(0, 118, 240, 17, TFT_BLACK);
  spr.setTextDatum(MC_DATUM);
  spr.setTextColor(gameOver ? TFT_DARKGREEN : TFT_SKYBLUE, TFT_BLACK);
  spr.drawString(gameOver ? ("SCORE: " + String(sharedScore) + "  Press for rematch") : ("SCORE: " + String(sharedScore) + "  "), 120, 126, 2);
  spr.setTextDatum(TL_DATUM);

  // Push completed buffer to screen
  spr.pushSprite(0, 0);
}

// render frame in sprite
void renderFrame() {
  if (gameOver) return;

  uint32_t now = millis();
  if (now - lastBubbleUpdate > 16) { // help with the lagging
    lastBubbleUpdate = now;
    drawScene((float)(now - roundStartTime));
  }
}

// For updates outside of the frame (like clicking and other player update)
void drawScreen() {
  float timeElapsed = gameOver ? -1.0f : (float)(millis() - roundStartTime);
  drawScene(timeElapsed);
}

void setup() {
  Serial.begin(115200);

  pinMode(BUTTON_A, INPUT_PULLUP);
  pinMode(BUTTON_B, INPUT);

  tft.init();
  tft.setRotation(1); // Landscape (240 x 135)
  tft.setSwapBytes(true); // needed for endianess

  // Initialize active render sprite
  spr.createSprite(240, 135); // same size as TFT display
  spr.setSwapBytes(true);

  // Initialize background sprite and pre-render background once
  bgSprite.createSprite(240, 135);
  bgSprite.setSwapBytes(true);
  bgSprite.pushImage(0, 0, 240, 135, bg);

  setupEspNow(); // start connection
  startNewRound(); // start round
}

void loop() {
  if (resetRequested) {
    resetRequested = false;
    startNewRound();
  }

  // Check if round elapsed past final beat + badDelta window
  if (!gameOver) {
    float roundDuration = getLatestBeatTime() + badDelta;
    if (millis() - roundStartTime >= roundDuration) {
      gameOver = true;
      gameOverAt = millis();
      sendState();
      needsRedraw = true;
    }
  }

  if (!gameOver) {
    renderFrame();
  }

  bool a = buttonPressed(BUTTON_A, lastA);
  bool b = buttonPressed(BUTTON_B, lastB);
  bool pressed = (a || b) && (millis() - lastPressTime > 30);

  if (pressed) {
    lastPressTime = millis();

    if (!gameOver) {
      float relativePressMs = (float)(millis() - roundStartTime);
      int targetIdx = findTargetNoteIndex(
        correctTimes[PLAYER_ID].timing,
        noteDone,
        correctTimes[PLAYER_ID].arraySize,
        relativePressMs
      );

      int deltaScore = 0;
      if (targetIdx < 0) {
        lastRating = 0;
        deltaScore = -100;
      } else {
        float absDelta = fabsf(correctTimes[PLAYER_ID].timing[targetIdx] - relativePressMs);
        if (absDelta > goodDelta) {
          lastRating = 1;
          deltaScore = -10;
        } else if (absDelta > perfectDelta) {
          lastRating = 2;
          deltaScore = 20;
        } else {
          lastRating = 3;
          deltaScore = 200;
        }
        noteDone[targetIdx] = true;
      }

      sharedScore += deltaScore;
      lastPlayerId = PLAYER_ID;
      lastScoreTime = millis(); //time for last score msg
      localBarRating = lastRating;

      sendState();
      needsRedraw = true;
    } else if (millis() - gameOverAt > 1500) {
      startNewRound();
      sendState(true);
    }
  }

  // Periodic heartbeat sync
  if (!gameOver && millis() - lastHeartbeat > HEARTBEAT_MS) {
    lastHeartbeat = millis();
    sendState();
  }

  if (needsRedraw) {
    needsRedraw = false;
    drawScreen();
  }
}