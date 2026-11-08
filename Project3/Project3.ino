/*
  Module 3: Button Mash Game for the ESP32 LILYGO T-Display
  Race to mash the buttons on the ESP32 the fastest.  The boards broadcast
  their button presses to each other using ESP-NOW.  Fastest wins.

  Supports 2-3 players (must modify TEAM_ID and PLAYER_ID). 
  - TEAM_ID:   should match for all members on a team
  - PLAYER_ID: unique for each member on a team (0, 1, or 2) 
*/

#include <WiFi.h>
#include <esp_now.h>
#include <TFT_eSPI.h>

#define TEAM_ID       3      // TODO: Modify based on your TEAM ID
#define PLAYER_ID     1      // TODO: Change to 0, 1, or 2. Each group member should have a unique ID.
#define MAX_PLAYERS   3
#define TARGET        40     // button presses to win
#define BUTTON_A      0      // left button (either button counts)
#define BUTTON_B      35    // right button (either button counts)
#define HEARTBEAT_MS  250

uint8_t broadcastAddress[] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};

TFT_eSPI tft = TFT_eSPI();

volatile uint16_t counts[MAX_PLAYERS] = {0, 0, 0};
volatile bool seen[MAX_PLAYERS]   = {false, false, false};
volatile bool resetRequested = false;

bool lastA = HIGH, lastB = HIGH;
uint32_t lastPressTime = 0;

const uint16_t playerColors[MAX_PLAYERS] = {TFT_CYAN, TFT_ORANGE, TFT_GREEN};

// message structure between devices
typedef struct {
  uint8_t  teamId;     // which group this message belongs to
  uint8_t  playerId;   // which player in the group sent it
  uint8_t  isReset;    // 1 = "start a new round"
  uint16_t presses;    // sender's total button presses so far
} Message;

// receive callback
void onReceive(const esp_now_recv_info_t *info, const uint8_t *data, int len) {
  if (len != sizeof(Message)) return;

  Message msg;
  memcpy(&msg, data, sizeof(msg));
  if (msg.teamId != TEAM_ID) return;                 // msgs from a different team
  if (msg.playerId >= MAX_PLAYERS) return;           // bad player number
  if (msg.playerId == PLAYER_ID) return;             // two boards with the same PLAYER_ID

  if (msg.isReset) {
    resetRequested = true;
  } else {
    score = msg.score;
    ratingOther = msg.rating;
    seen[msg.playerId] = true;
  }
}

void setupEspNow() {
  WiFi.mode(WIFI_STA);
  if (esp_now_init() != ESP_OK) {
    tft.fillScreen(TFT_BLACK);
    tft.setTextColor(TFT_RED);
    tft.drawString("ESP-NOW init failed", 10, 60, 2);
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
  msg.teamId   = TEAM_ID;
  msg.playerId = PLAYER_ID;
  msg.isReset  = reset ? 1 : 0;
  msg.rating  = rating;
  msg.score = score;
  esp_now_send(broadcastAddress, (uint8_t *)&msg, sizeof(msg)); // where state is broadcasted
}

// GAME LOGIC
void startNewRound() {
  for (int i = 0; i < MAX_PLAYERS; i++) counts[i] = 0;
  gameOver = false;
}

bool buttonPressed(uint8_t pin, bool &last) {
  bool now = digitalRead(pin);
  bool pressed = (last == HIGH && now == LOW);
  last = now;
  return pressed;
}

float deltaPressRecursive(float correctTimes[], int arraySize, float pressedTime, int lastIdx) {
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

struct timeList {
  int playerId;
  int arraySize;
  float timing[50];
};

timeList correctTimes[] = {
  { 1, 3, {1.5, 2.3, 3.1} }, 
  { 2, 3, {2.0, 4.5, 6.2} }  
};

int score = 0;
int lastIdx = 0;
float perfectDelta = 100;
float goodDelta = 500;
float badDelta = 1000;
int rating;

void setup() {
  Serial.begin(115200);

  pinMode(BUTTON_A, INPUT_PULLUP);
  pinMode(BUTTON_B, INPUT);          // GPIO 35 has an external pull-up on the board

  tft.init();
  tft.setRotation(1);                // landscape, 240 x 135
  tft.fillScreen(TFT_BLACK);

  setupEspNow();
}

void loop() {
  if (resetRequested) {
    resetRequested = false;
    startNewRound();
  }

  bool a = buttonPressed(BUTTON_A, lastA);
  bool b = buttonPressed(BUTTON_B, lastB);
  bool pressed = (a || b) && (millis() - lastPressTime > 20); // small debounce built in

  if (pressed) {
    lastPressTime = millis();

    if (!gameOver) {
      delta = deltaPressRecursive(correctTimes[playerId].timing, correctTimes[playerId].arraySize, float millis(), 0)

      if (delta > badDelta) {
        // miss
        rating = 0;
        score -= 100;
      } else if (delta > goodDelta) {
        // bad
        rating = 1;
        score -= 10;
      } else if (delta > perfectDelta) {
        // good
        rating = 2;
        score += 20
      } else {
        rating = 3;
        score += 200;
      }
      sendState();
      needsRedraw = true;
    } else if (millis() - gameOverAt > 1500) {
      startNewRound();
      sendState(true);               // reset for everyone
    }
  }

  // resend our total so a lost packet gets corrected
  if (!gameOver && millis() - lastHeartbeat > HEARTBEAT_MS) {
    lastHeartbeat = millis();
    sendState();
  }

  // only redraw only when something changed
  if (needsRedraw) {
    needsRedraw = false;
    drawScreen();
  }
}
