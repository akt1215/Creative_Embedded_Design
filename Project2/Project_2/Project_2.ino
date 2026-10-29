int xyzPins[] = {39, 32, 33};
int PIN_POT    = 13;
int PIN_BUTTON = 2;
int PIN_LED    = 15;

// Send controller readings at a steady rate
unsigned long lastSendTime = 0;
const unsigned long SEND_INTERVAL_MS = 16;

void setup() {
  Serial.begin(9600);
  pinMode(PIN_BUTTON, INPUT_PULLUP);
  pinMode(xyzPins[2], INPUT_PULLUP);
  pinMode(PIN_LED, OUTPUT);
  digitalWrite(PIN_LED, LOW);
}

void loop() {
  while (Serial.available() > 0) {
    char cmd = Serial.read();
    if (cmd == '1') {
      digitalWrite(PIN_LED, HIGH);
    } else if (cmd == '0') {
      digitalWrite(PIN_LED, LOW);
    }
  }

  unsigned long now = millis();
  if (now - lastSendTime >= SEND_INTERVAL_MS) {
    lastSendTime = now;

    int xVal   = analogRead(xyzPins[0]);   // 0 - 4095
    int yVal   = analogRead(xyzPins[1]);   // 0 - 4095
    int potVal = analogRead(PIN_POT);     // 0 - 4095

    // Check reset triggers (either dedicated button or joystick press)
    int btnState = digitalRead(PIN_BUTTON);
    int joySw    = digitalRead(xyzPins[2]);
    int resetActive = (btnState == LOW || joySw == LOW) ? 0 : 1; // 0 = pressed

    // Packet format: joyX,joyY,potVal,resetBtn\n
    Serial.printf("%d,%d,%d,%d\n", xVal, yVal, potVal, resetActive);
  }
}
