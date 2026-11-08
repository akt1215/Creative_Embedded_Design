/*
  Cooperative Button / Rhythm Game for ESP32 LILYGO T-Display
  Players collaborate on a shared score over ESP-NOW.
  The round concludes automatically once the final beat timing has passed.
*/

#include <WiFi.h>
#include <esp_now.h>
#include <TFT_eSPI.h>
#include <cmath>

#define TEAM_ID       3      // Must match for all teammates
#define PLAYER_ID     1      // Unique per board: 0, 1, or 2
#define MAX_PLAYERS   3
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

// Timing Windows (milliseconds)
const float perfectDelta = 150.0f;
const float goodDelta    = 400.0f;
const float badDelta     = 800.0f;

struct TimeList {
  int arraySize;
  float timing[10];
};

// Target beat offsets relative to round start (in milliseconds)
TimeList correctTimes[MAX_PLAYERS] = {
  {4, {1000.0f, 3000.0f, 4500.0f, 6000.0f}},
  {4, {1000.0f, 3000.0f, 4500.0f, 6000.0f}},
  {4, {1000.0f, 3000.0f, 4500.0f, 6000.0f}}
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

void drawScreen();

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

    // Sync game-over trigger from teammates
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

float deltaPressRecursive(const float times[], int arraySize, float pressedTime, int lastIdx) {
  if (lastIdx >= arraySize - 1) {
    return times[lastIdx] - pressedTime;
  }

  float delta1 = times[lastIdx] - pressedTime;
  float delta2 = times[lastIdx + 1] - pressedTime;

  if (fabsf(delta1) <= fabsf(delta2)) {
    return delta1;
  } else {
    return deltaPressRecursive(times, arraySize, pressedTime, lastIdx + 1);
  }
}

void drawScreen() {
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

  // Check if round elapsed past the final beat + badDelta window
  if (!gameOver) {
    float roundDuration = getLatestBeatTime() + badDelta;
    if (millis() - roundStartTime >= roundDuration) {
      gameOver = true;
      gameOverAt = millis();
      sendState();
      needsRedraw = true;
    }
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

      sharedScore += deltaScore;
      lastPlayerId = PLAYER_ID;

      sendState();
      needsRedraw = true;
    } else if (millis() - gameOverAt > 1500) {
      // Manual reset on button press after song finishes
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