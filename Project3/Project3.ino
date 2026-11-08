/*
  Cooperative Button / Rhythm Game for ESP32 LILYGO T-Display
  All players on the same TEAM_ID work together to reach TARGET_SCORE.
  Any player's press updates the shared team score over ESP-NOW.
*/

#include <WiFi.h>
#include <esp_now.h>
#include <TFT_eSPI.h>
#include <cmath>

#define TEAM_ID       3      // Must match for all teammates
#define PLAYER_ID     1      // Unique per board: 0, 1, or 2
#define MAX_PLAYERS   3
#define TARGET_SCORE  1000   // Combined score needed to win
#define BUTTON_A      0      // Left button
#define BUTTON_B      35     // Right button (hardware pull-up on board)
#define HEARTBEAT_MS  250

uint8_t broadcastAddress[] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};

TFT_eSPI tft = TFT_eSPI();

// Shared Game State
int sharedScore                 = 0;
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

const uint16_t playerColors[MAX_PLAYERS] = {TFT_CYAN, TFT_ORANGE, TFT_GREEN};
const char* ratingLabels[] = {"MISS (-100)", "BAD (-10)", "GOOD (+20)", "PERFECT! (+200)"};
const uint16_t ratingColors[] = {TFT_RED, TFT_MAGENTA, TFT_YELLOW, TFT_GREEN};

// Timing Windows (milliseconds)
const float perfectDelta = 150.0f;
const float goodDelta    = 400.0f;
const float badDelta     = 800.0f;

struct TimeList {
  int arraySize;
  float timing[10];
};

// Target beat offsets relative to round start (ms)
TimeList correctTimes[MAX_PLAYERS] = {
  {4, {1, 3, 4.5, 6}},
  {4, {1, 3, 4.5, 6}},
  {4, {1, 3, 4.5, 6}}
};

// Packet format
typedef struct {
  uint8_t  teamId;
  uint8_t  playerId;
  uint8_t  isReset;
  int16_t  sharedScore;
  uint8_t  rating;
} Message;

void drawScreen();

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
    // Update local copy of the shared score
    sharedScore  = msg.sharedScore;
    lastRating   = msg.rating;
    lastPlayerId = msg.playerId;
    seen[msg.playerId] = true;

    if (sharedScore >= TARGET_SCORE && !gameOver) {
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
  msg.rating      = (uint8_t)lastRating;
  msg.sharedScore = (int16_t)sharedScore;
  esp_now_send(broadcastAddress, (uint8_t *)&msg, sizeof(msg));
}

void startNewRound() {
  sharedScore = 0;
  lastRating = 3;
  lastPlayerId = PLAYER_ID;
  gameOver = false;
  roundStartTime = millis();
  seen[PLAYER_ID] = true;
  needsRedraw = true;
}

bool buttonPressed(uint8_t pin, bool &last) {
  bool now = digitalRead(pin);
  bool pressed = (last == HIGH && now == LOW);
  last = now;
  return pressed;
}

float deltaPressRecursive(const float correctTimes[], int arraySize, float pressedTime, int lastIdx) {
  if (lastIdx >= arraySize - 1) {
    return correctTimes[lastIdx] - pressedTime;
  }

  float delta1 = correctTimes[lastIdx] - pressedTime;
  float delta2 = correctTimes[lastIdx + 1] - pressedTime;

  if (fabsf(delta1) <= fabsf(delta2)) {
    return delta1;
  } else {
    return deltaPressRecursive(correctTimes, arraySize, pressedTime, lastIdx + 1);
  }
}

void drawScreen() {
  tft.fillScreen(TFT_BLACK);

  // 1. Top Header
  tft.setTextDatum(TL_DATUM);
  tft.setTextColor(TFT_LIGHTGREY, TFT_BLACK);
  tft.drawString("TEAM " + String(TEAM_ID) + " CO-OP", 8, 6, 2);

  tft.setTextDatum(TR_DATUM);
  tft.setTextColor(playerColors[PLAYER_ID], TFT_BLACK);
  tft.drawString("YOU: P" + String(PLAYER_ID), 232, 6, 2);

  // 2. Large Central Team Score
  tft.setTextDatum(MC_DATUM);
  tft.setTextColor(TFT_WHITE, TFT_BLACK);
  tft.drawString(String(sharedScore) + " / " + String(TARGET_SCORE), 120, 48, 4);

  // Score Progress Bar
  int barWidth = 200;
  int barHeight = 8;
  int x = 20;
  int y = 70;
  int progress = constrain((sharedScore * barWidth) / TARGET_SCORE, 0, barWidth);
  
  tft.drawRect(x - 1, y - 1, barWidth + 2, barHeight + 2, TFT_DARKGREY);
  tft.fillRect(x, y, progress, barHeight, TFT_CYAN);
  tft.fillRect(x + progress, y, barWidth - progress, barHeight, TFT_BLACK);

  // 3. Last Action Feedback (Who scored what)
  tft.setTextDatum(MC_DATUM);
  tft.setTextColor(playerColors[lastPlayerId], TFT_BLACK);
  String feed = "P" + String(lastPlayerId) + ": ";
  tft.drawString(feed + ratingLabels[lastRating], 120, 95, 2);

  // 4. Teammate Status Indicator (Bottom)
  tft.setTextDatum(BC_DATUM);
  String roster = "";
  for (int i = 0; i < MAX_PLAYERS; i++) {
    roster += (i == PLAYER_ID ? "[P" : " P") + String(i);
    roster += (seen[i] || i == PLAYER_ID ? "*] " : "?] ");
  }
  tft.setTextColor(TFT_DARKGREY, TFT_BLACK);
  tft.drawString(roster, 120, 130, 2);

  // 5. Game Over Banner
  if (gameOver) {
    tft.fillRect(0, 35, 240, 65, TFT_NAVY);
    tft.setTextColor(TFT_YELLOW, TFT_NAVY);
    tft.setTextDatum(MC_DATUM);
    tft.drawString("VICTORY!", 120, 55, 4);
    tft.drawString("Target Reached!", 120, 85, 2);
  }
}

void setup() {
  Serial.begin(115200);

  pinMode(BUTTON_A, INPUT_PULLUP);
  pinMode(BUTTON_B, INPUT);

  tft.init();
  tft.setRotation(1); // Landscape (240 x 135)
  tft.fillScreen(TFT_BLACK);

  setupEspNow();
  startNewRound();
}

void loop() {
  if (resetRequested) {
    resetRequested = false;
    startNewRound();
  }

  bool a = buttonPressed(BUTTON_A, lastA);
  bool b = buttonPressed(BUTTON_B, lastB);
  bool pressed = (a || b) && (millis() - lastPressTime > 30);

  if (pressed) {
    lastPressTime = millis();

    if (!gameOver) {
      float relativePressMs = (float)(millis() - roundStartTime);
      float delta = deltaPressRecursive(
        correctTimes[PLAYER_ID].timing,
        correctTimes[PLAYER_ID].arraySize,
        relativePressMs,
        0
      );

      float absDelta = fabsf(delta);
      int deltaScore = 0;

      if (absDelta > badDelta) {
        lastRating = 0;
        deltaScore = -100;
      } else if (absDelta > goodDelta) {
        lastRating = 1;
        deltaScore = -10;
      } else if (absDelta > perfectDelta) {
        lastRating = 2;
        deltaScore = 20;
      } else {
        lastRating = 3;
        deltaScore = 200;
      }

      // Add to shared total
      sharedScore += deltaScore;
      lastPlayerId = PLAYER_ID;

      if (sharedScore >= TARGET_SCORE) {
        gameOver = true;
        gameOverAt = millis();
      }

      sendState();
      needsRedraw = true;
    } else if (millis() - gameOverAt > 2000) {
      // Automatic reset after victory screen
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