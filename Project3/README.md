# coms3930-module-3: Distributed Communications

<img width="316" height="222" alt="Adobe Express - gameplay" src="https://github.com/user-attachments/assets/e63626f4-d984-4c75-84bb-0ca0e62f9a06" />

From the starter competitive game implemented by the professor, Module 3 had us alter it in pairs to turn it into a collaborative game. Using only the ESP32 (without it being necessary to add any external hardware), we gained experience with the ESP-NOW communication protocol.

Our transition from a multiplayer competitive button masher game to a cooperative game was inspired by Taiko no Tatsujin, a Japanese rhythm video game. The players must hit the bubbles as they pass by the target line to gain points, and will lose points if they have poor timing, in order to increase the shared score between the players. The bubbles are not synchronized between devices; rather each player has to focus on doing their part. The goal is to collectively aim to score the most points and to not diminish your partner's efforts by not losing points.

The only component used is a LilyGO TTGO T-Display ESP32, with the sensor data processed in an Arduino program.

<img width="1765" height="530" alt="image" src="https://github.com/user-attachments/assets/0ee7f6cc-308d-4d6a-bf16-ccd2548354c6" />

## Code - Design Choices
### To change the background img
- Convert your desired image to a bitmap and size it to your display's dimensions (240 × 135). Make sure to save import as a .h file in your Arduino program;
- Ensure that both the bg.h file and the Arduino code are under the same directory. 

### To change the player/bubbles' colours and score's points/message
To personalise the bubble's in the game, you have to modify the colour atributed to that player. You can change the labelling for rating by modifying the message and the assigned points in the following array:
```c
const uint16_t playerColors[MAX_PLAYERS] = {TFT_CYAN, TFT_ORANGE, TFT_GREEN};
const char* ratingLabels[] = {"MISS (-100)", "BAD (-10)", "GOOD (+20)", "PERFECT! (+200)"};
```

### To change timing windows
If you want to adjust the sensibility to the user's button presses and how it related to scoring, change the following attributes (in milliseconds)
```c
const float perfectDelta = 45.0f;
const float goodDelta    = 120.0f;
const float badDelta     = 240.0f;
```

## Code - Game System/ Logic
### ESP-NOW Communication
We used the ESP-NOW protocol to communicate between the two ESP32 devices. We used our given template from the class lab to implement the specific functions to send and receive data. The data sent is a struct containing the player's score, the number of bubbles hit, and the number of bubbles missed. The receiving device updates its own score based on the received data.
```c
typedef struct {
  uint8_t  teamId;
  uint8_t  playerId;
  uint8_t  isReset;
  uint8_t  isGameOver;
  int16_t  sharedScore;
  uint8_t  rating;
} Message;
```

### To change amount and timing of bubbles
The timing of the bubbles is defined in the struct with the array size and the array of the timing of each bubble. The array size is made easily accessible in other parts of the code.
```c
struct TimeList {
  int arraySize;
  float timing[MAX_NOTES];
};

TimeList correctTimes[MAX_PLAYERS] = {
  // Player 0: syncopated tresillo groove + double-tap break
  {13, {1500.0f, 2400.0f, 3300.0f, 3900.0f, 4500.0f, 5400.0f, 6000.0f, 6300.0f, 7500.0f, 8400.0f, 9300.0f, 9900.0f, 10500.0f}},
  // Player 1: off-beat call-and-response + double-tap fills
  {13, {1800.0f, 2700.0f, 3000.0f, 3900.0f, 4800.0f, 5100.0f, 6300.0f, 6900.0f, 7200.0f, 8100.0f, 8700.0f, 9600.0f, 10500.0f}},
  // Player 2: gallop bursts + cross-rhythm + accelerating finale
  {16, {1500.0f, 2100.0f, 2450.0f, 2800.0f, 3900.0f, 4250.0f, 5100.0f, 5700.0f, 6300.0f, 7050.0f, 7800.0f, 8550.0f, 9300.0f, 9750.0f, 10125.0f, 10500.0f}}
};
```
In the current implementation, each player receives a unique pattern of bubbles. However, if you want them to be synchronised, simply have their values be the same.

### Scoring System
We set the scoring system to be based on the delta between the time the bubble reaches the target line and the players button press. We defined four timing windows for scoring: perfect, good, bad, and miss (<=45ms, <=120ms, <=240ms, and >240ms) based on what I felt reasonable when testing. 
```c 
// Timing Windows (milliseconds)
const float perfectDelta = 45.0f;
const float goodDelta    = 120.0f;
const float badDelta     = 240.0f;

...

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
```

### Game Ending Logic
The game ends when the last bubble has passed the target line and passed the timing window for "bad" (240ms).
```c 
float roundDuration = getLatestBeatTime() + badDelta;
if (millis() - roundStartTime >= roundDuration) {
  gameOver = true;
  gameOverAt = millis();
  sendState();
  needsRedraw = true;
}
```