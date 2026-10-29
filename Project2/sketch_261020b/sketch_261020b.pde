import processing.serial.*;
import javax.sound.sampled.*;
import java.io.File;


// Part 1: Connecting hardware to the control of the game

Serial myPort;
String val;
int analogMax = 4095;
int lastEspResetBtn = 0;
boolean lastLedActive = false;

// Processed controller vectors
PVector joyRaw = new PVector(0, 0); // Normalized flight vector [-1.0, 1.0]
float joyDeadzone = 0.15;           // Deadband filter for joystick resting drift
float calibrationAngle = 0;         // P2 alignment angle [0, TWO_PI]

void setup() {
  size(800, 700, P2D);
  smooth(8);

  printArray(Serial.list());
  String portName = Serial.list()[4];
  println(portName);
  myPort = new Serial(this, portName, 9600);

  // Initialize the game engine
  setupGameEngine();
}

void draw() {
  if (myPort.available() > 0) {
    val = myPort.readStringUntil('\n');
  }
  val = trim(val);
  if (val != null) {
    int[] data = int(split(val, ','));

    if (data.length >= 4) {
      int xVal   = data[0];
      int yVal   = data[1];
      int potVal = data[2];
      int btnVal = data[3];

      // Map the joystick to flight vector [-1.0, 1.0]
      float jx = map(xVal, 0, analogMax, -1.0, 1.0);
      float jy = map(yVal, 0, analogMax, -1.0, 1.0);

      // Filter small joystick movements around the resting center
      if (abs(jx) < 0.14) jx = 0;
      if (abs(jy) < 0.14) jy = 0;
      joyRaw.set(jx, jy);
      if (joyRaw.mag() > 1.0) joyRaw.normalize();
      if (joyRaw.mag() < joyDeadzone) joyRaw.set(0, 0);

      // Mapping of the potentiometer (technically, it doesn't rotate full 360 degrees, but the game play was fine so keep it this way to make things simpler)
      calibrationAngle = map(potVal, 0, analogMax, 0, TWO_PI);

      if (btnVal == 1 && lastEspResetBtn == 0) {
        triggerHardwareReset();
      }
      lastEspResetBtn = btnVal;
    }
    val = null;
  }

  sendHardwareLedSignal();
  updateAndRenderGame();
}

void sendHardwareLedSignal() {
  // Turn on the LED when drone hits a wall
  boolean ledActive = (zapFlash > 0 || recoilStun > 0 || damageFlash > 0);
  if (ledActive != lastLedActive && myPort != null) {
    lastLedActive = ledActive;
    if (ledActive) {
      myPort.write('1');
    } else {
      myPort.write('0');
    }
  }
}

void triggerHardwareReset() {
  if (state == GameState.GAME_WIN || state == GameState.GAME_LOSE || state == GameState.LEADERBOARD) {
    restartGame();
  }
}


// PART 2: Game engine, physics, sound, and animation

enum GameState { PLAYING, ROUND_WIN, GAME_WIN, GAME_LOSE, LEADERBOARD }
GameState state = GameState.PLAYING;

// --- Drone Physics ---
PVector pointPos = new PVector(0, 0), pointVel = new PVector(0, 0), knockback = new PVector(0, 0);
PVector targetPos = new PVector(0, 0), startPos = new PVector(0, 0);
float pointRadius = 11, targetRadius = 24, moveSpeed = 3.6;
float pointHeading = 0, targetHeading = 0, bankAngle = 0, recoilStun = 0, shieldPulse = 1.0;
float droneHp = 100, maxHp = 100, displayHp = 100, damageFlash = 0;

// --- Scramble & Misalignment State ---
float hiddenRotation = 0, scrambleTimer = 0, scrambleInterval = 25.0, scrambleFlash = 0;
int scrambleCount = 0, lastWarningSecond = -1;

// --- Maze Structure ---
ArrayList<Wall> walls = new ArrayList<Wall>();
ArrayList<PVector> wallNodes = new ArrayList<PVector>();
float cellW, cellH;

// --- Rules & Scoring ---
float roundTimer = 0, roundTimeLimit = 60.0;
int level = 1, winsNeeded = 3;
float navAccuracySum = 0, teamTotalScore = 0;
int navAccuracySamples = 0, sectorWallHits = 0;
float p1Points = 0, p2Points = 0, p1RoundPoints = 0, p2RoundPoints = 0;
float lastP1Accuracy = 1.0, lastP2Accuracy = 1.0, zapFlash = 0, zapCooldown = 0;

// --- Leaderboard & Name Entry ---
ArrayList<ScoreEntry> leaderboard = new ArrayList<ScoreEntry>();
String playerInputName = "";
boolean scoreRecorded = false;
final int MAX_NAME_LEN = 12;

// --- VFX & Cameras ---
ArrayList<Particle> fx = new ArrayList<Particle>();
ArrayList<Star> stars = new ArrayList<Star>();
float shakeAmount = 0, globalTime = 0, roundWinTimer = 0, cameraZoom = 1.0, cameraTarget = 1.0;

// --- UI Layout & Audio ---
float playAreaX = 60, playAreaY = 125, playAreaW = 680, playAreaH = 445;
PFont monoFont = null, titleFont = null;
Clip sndZap, sndPortal, sndScramble, sndBeep, sndExplode, sndAmbient, sndThruster;
boolean thrusterPlaying = false;

void setupGameEngine() {
  try {
    monoFont  = createFont("Monospaced", 13, true);
    titleFont = createFont("SansSerif", 36, true);
  } catch (Exception e) {
    monoFont = null; titleFont = null;
  }

  initAudioSynthesizer();
  playLoopAudio(sndAmbient);
  clearLeaderboard();

  for (int i = 0; i < 90; i++) stars.add(new Star());
  newRound();
  randomizeHiddenRotation();
}

void updateAndRenderGame() {
  globalTime += 0.016;
  cameraZoom = lerp(cameraZoom, cameraTarget, 0.08);

  float sx = (shakeAmount > 0.4) ? random(-shakeAmount, shakeAmount) : 0;
  float sy = (shakeAmount > 0.4) ? random(-shakeAmount, shakeAmount) : 0;
  shakeAmount *= 0.86;

  pushMatrix();
  translate(sx, sy);
  drawBackdrop();

  if (state != GameState.PLAYING) stopThrusterAudio();

  switch (state) {
    case PLAYING:
      updateGame();
      updateThrusterAudio();
      updateFX();
      drawGame();
      break;
    case ROUND_WIN:
      updateFX();
      updateRoundWin();
      drawGame();
      drawRoundOverlay();
      break;
    case GAME_WIN:
    case GAME_LOSE:
      updateFX();
      drawGame();
      drawTerminalOverlay(state == GameState.GAME_WIN);
      break;
    case LEADERBOARD:
      drawLeaderboardScreen();
      break;
  }
  popMatrix();
}

void updateGame() {
  roundTimer += 1.0 / frameRate;
  if (zapCooldown > 0) zapCooldown -= 1.0 / frameRate;
  if (recoilStun > 0)  recoilStun  -= 1.0 / frameRate;
  if (damageFlash > 0) damageFlash -= 1.0 / frameRate;
  shieldPulse = lerp(shieldPulse, 1.0, 0.08);
  displayHp = lerp(displayHp, droneHp, 0.18);

  float effectiveAngle = hiddenRotation - calibrationAngle;

  if (joyRaw.mag() > 0.15) {
    float angleErr = abs(circularAngleDiff(hiddenRotation, calibrationAngle));
    navAccuracySum += constrain(map(cos(angleErr), 1.0, -0.6, 1.0, 0.0), 0.0, 1.0);
    navAccuracySamples++;
  }

  if (roundTimer >= roundTimeLimit) {
    droneHp = 0;
    stopThrusterAudio();
    playAudio(sndExplode);
    shakeAmount = 26;
    state = GameState.GAME_LOSE;
    return;
  }

  PVector targetDir = rotateVector(joyRaw, effectiveAngle);
  float controlAuthority = (recoilStun > 0) ? 0.45 : 1.0;
  pointVel.lerp(PVector.mult(targetDir, moveSpeed * controlAuthority), 0.22);

  if (pointVel.mag() > 0.15) {
    targetHeading = atan2(pointVel.y, pointVel.x);
    float angleDelta = circularAngleDiff(targetHeading, pointHeading);
    pointHeading = lerpAngle(pointHeading, targetHeading, 0.24);
    bankAngle = lerp(bankAngle, constrain(angleDelta * 2.2, -0.7, 0.7), 0.18);
  } else {
    bankAngle = lerp(bankAngle, 0, 0.1);
  }

  pointPos.add(knockback);
  knockback.mult(0.76);

  int steps = 4;
  float dx = pointVel.x / steps, dy = pointVel.y / steps;
  for (int s = 0; s < steps; s++) {
    pointPos.x += dx; pointPos.y += dy;
    if (resolveWallCollisions()) break;
  }

  // Arena perimeter bounds
  if (pointPos.x < playAreaX + pointRadius) { pointPos.x = playAreaX + pointRadius; knockback.x = 3.5; pointVel.x = 0; }
  if (pointPos.x > playAreaX + playAreaW - pointRadius) { pointPos.x = playAreaX + playAreaW - pointRadius; knockback.x = -3.5; pointVel.x = 0; }
  if (pointPos.y < playAreaY + pointRadius) { pointPos.y = playAreaY + pointRadius; knockback.y = 3.5; pointVel.y = 0; }
  if (pointPos.y > playAreaY + playAreaH - pointRadius) { pointPos.y = playAreaY + playAreaH - pointRadius; knockback.y = -3.5; pointVel.y = 0; }

  if (joyRaw.mag() > 0.1) spawnThrusterPlasma();

  if (dist(pointPos.x, pointPos.y, targetPos.x, targetPos.y) < targetRadius) {
    playAudio(sndPortal);
    spawnBurst(targetPos.x, targetPos.y, 70, color(60, 255, 180), 8.5);
    shakeAmount = 18;
    computeRoundRating(true);
    level++;
    cameraTarget = 1.1;
    droneHp = min(maxHp, droneHp + 25);
    state = (level > winsNeeded) ? GameState.GAME_WIN : GameState.ROUND_WIN;
    roundWinTimer = 0;
  }

  scrambleTimer += 1.0 / frameRate;
  float shiftRemain = max(0, scrambleInterval - scrambleTimer);
  int secLeft = ceil(shiftRemain);
  if (shiftRemain <= 3.0 && secLeft != lastWarningSecond && secLeft > 0) {
    lastWarningSecond = secLeft;
    playAudio(sndBeep);
  }

  if (scrambleTimer >= scrambleInterval) {
    scrambleTimer = 0;
    lastWarningSecond = -1;
    randomizeHiddenRotation();
    playAudio(sndScramble);
    scrambleFlash = 45;
    scrambleCount++;
    shakeAmount = 16;
    spawnBurst(playAreaX + playAreaW/2, playAreaY + playAreaH/2, 45, color(255, 60, 60), 7.5);
  }
  if (scrambleFlash > 0) scrambleFlash--;
  if (zapFlash > 0) zapFlash--;
}

boolean resolveWallCollisions() {
  boolean zapped = false;
  float lx = pointPos.x - playAreaX, ly = pointPos.y - playAreaY;

  for (Wall w : walls) {
    float cx = constrain(lx, w.x, w.x + w.w), cy = constrain(ly, w.y, w.y + w.h);
    float dx = lx - cx, dy = ly - cy, d2 = dx*dx + dy*dy;

    if (d2 < pointRadius * pointRadius) {
      float d = sqrt(d2);
      float nx = (d > 0.001) ? dx / d : 1, ny = (d > 0.001) ? dy / d : 0;
      float overlap = pointRadius - d;

      lx += nx * (overlap + 1.0);
      ly += ny * (overlap + 1.0);

      if (zapCooldown <= 0 && !zapped) {
        knockback.set(nx * 4.8, ny * 4.8);
        pointVel.set(0, 0);
        recoilStun = 0.10;
        playAudio(sndZap);
        shakeAmount = 12;
        zapFlash = 20;
        zapCooldown = 0.35;
        shieldPulse = 1.8;
        damageFlash = 0.30;
        sectorWallHits++;
        droneHp = max(0, droneHp - 15.0);

        for (int i = 0; i < 18; i++) {
          float spd = random(2.5, 6.0), ang = atan2(ny, nx) + random(-0.8, 0.8);
          fx.add(new Particle(cx + playAreaX, cy + playAreaY, cos(ang)*spd, sin(ang)*spd,
                 color(255, random(80, 180), 60), random(3.5, 6.5), random(0.03, 0.07)));
        }

        if (droneHp <= 0) {
          stopThrusterAudio();
          playAudio(sndExplode);
          shakeAmount = 26;
          spawnBurst(pointPos.x, pointPos.y, 60, color(255, 60, 60), 9.0);
          computeRoundRating(false);
          state = GameState.GAME_LOSE;
        }
        zapped = true;
      }
    }
  }
  pointPos.set(playAreaX + lx, playAreaY + ly);
  return zapped;
}

void computeRoundRating(boolean reachedTarget) {
  lastP2Accuracy = (navAccuracySamples > 0) ? (navAccuracySum / navAccuracySamples) : 0.85;
  float pilotFaults = (sectorWallHits * 0.08) + ((maxHp - droneHp) * 0.003);
  lastP1Accuracy = constrain(1.0 - pilotFaults, 0.30, 1.0);

  float timeBonus = max(0, (roundTimeLimit - roundTimer) * 22.0);
  float hullBonus = droneHp * 8.0;
  float clearBonus = reachedTarget ? 1000.0 : 200.0;
  float teamRoundPoints = clearBonus + timeBonus + hullBonus;

  p1RoundPoints = teamRoundPoints * 0.5 * (lastP1Accuracy / 0.9);
  p2RoundPoints = teamRoundPoints * 0.5 * (lastP2Accuracy / 0.9);
  p1Points += p1RoundPoints;
  p2Points += p2RoundPoints;
  teamTotalScore = p1Points + p2Points;

  navAccuracySum = 0;
  navAccuracySamples = 0;
  sectorWallHits = 0;
}

void drawBackdrop() {
  noStroke();
  for (int i = 0; i < height; i += 8) {
    fill(lerpColor(color(5, 7, 16), color(14, 11, 26), (float)i / height));
    rect(0, i, width, 8);
  }
  for (Star s : stars) s.render();

  stroke(100, 50, 180, 20);
  strokeWeight(1);
  for (float x = 0; x <= width; x += 60) line(x, height * 0.72, width/2 + (x - width/2)*2.0, height);
}

void drawGame() {
  pushMatrix();
  translate(playAreaX + playAreaW*0.5, playAreaY + playAreaH*0.5);
  scale(cameraZoom);
  translate(-(playAreaX + playAreaW*0.5), -(playAreaY + playAreaH*0.5));

  fill(11, 13, 24, 245);
  stroke(40, 70, 120, 90);
  strokeWeight(1.5);
  rect(playAreaX, playAreaY, playAreaW, playAreaH, 6);

  stroke(30, 45, 80, 40);
  strokeWeight(1);
  for (float gx = playAreaX; gx <= playAreaX + playAreaW; gx += cellW) line(gx, playAreaY, gx, playAreaY + playAreaH);
  for (float gy = playAreaY; gy <= playAreaY + playAreaH; gy += cellH) line(playAreaX, gy, playAreaX + playAreaW, gy);

  drawMazeWalls();
  drawPortal(targetPos.x, targetPos.y);
  drawVFX();
  drawKineticDrone(pointPos.x, pointPos.y);

  noFill();
  stroke(70, 150, 255, 160);
  strokeWeight(2);
  rect(playAreaX, playAreaY, playAreaW, playAreaH, 6);

  if (scrambleFlash > 0) {
    stroke(255, 50, 60, scrambleFlash * 6);
    strokeWeight(6);
    rect(playAreaX, playAreaY, playAreaW, playAreaH, 6);
    setUiText(titleFont, 34, CENTER, CENTER, color(255, 70, 80, min(255, scrambleFlash * 7)));
    text("AXES SCRAMBLED", playAreaX + playAreaW/2, playAreaY + 45);
  }

  if (zapFlash > 0) {
    stroke(255, 210, 80, zapFlash * 11);
    strokeWeight(4);
    rect(playAreaX, playAreaY, playAreaW, playAreaH, 6);
  }

  drawHUD();
  popMatrix();
}

void drawMazeWalls() {
  for (Wall w : walls) {
    float wx = playAreaX + w.x, wy = playAreaY + w.y;
    noStroke();
    fill(4, 6, 12, 160);
    rect(wx + 3, wy + 4, w.w, w.h, 3);
    fill(20, 24, 38);
    stroke(45, 60, 90);
    strokeWeight(1);
    rect(wx, wy, w.w, w.h, 3);
    noStroke();
    fill(255, 50, 90, 45);
    rect(wx + 2, wy + 2, max(1, w.w - 4), max(1, w.h - 4), 2);
    stroke(255, 70, 110, 200);
    strokeWeight(1.4);
    line(wx + 3, wy + w.h/2, wx + w.w - 3, wy + w.h/2);
    line(wx + w.w/2, wy + 3, wx + w.w/2, wy + w.h - 3);
  }

  for (PVector node : wallNodes) {
    float nx = playAreaX + node.x, ny = playAreaY + node.y;
    noStroke();
    fill(255, 80, 120, 120 + 60 * sin(globalTime * 4 + nx));
    ellipse(nx, ny, 7, 7);
    stroke(255, 120, 160);
    strokeWeight(1.2);
    noFill();
    ellipse(nx, ny, 11, 11);
  }
}

void drawKineticDrone(float x, float y) {
  pushMatrix();
  translate(x, y);

  float sR = pointRadius * (2.2 * shieldPulse);
  noStroke();
  fill((damageFlash > 0) ? color(255, 60, 70, 130) : (zapFlash > 0 ? color(255, 200, 80, 120) : color(80, 190, 255, 25)));
  ellipse(0, 0, sR, sR);
  noFill();
  stroke(damageFlash > 0 ? color(255, 80, 80, 240) : (zapFlash > 0 ? color(255, 200, 80, 220) : color(100, 220, 255, 120)));
  strokeWeight(damageFlash > 0 ? 2.8 : (zapFlash > 0 ? 2.5 : 1.2));
  ellipse(0, 0, sR, sR);

  float shiftRemain = max(0, scrambleInterval - scrambleTimer);
  float jitter = (shiftRemain < 3.5) ? random(-0.16, 0.16) * (1.0 - shiftRemain / 3.5) : 0;

  pushMatrix();
  rotate(calibrationAngle + jitter);
  stroke(shiftRemain < 3.5 ? color(255, 120, 120, 150) : color(120, 220, 255, 70));
  strokeWeight(1);
  for (int i = 0; i < 4; i++) arc(0, 0, pointRadius * 2.8, pointRadius * 2.8, i * HALF_PI + 0.15, (i+1) * HALF_PI - 0.15);
  fill(shiftRemain < 3.5 ? color(255, 140, 140) : color(120, 230, 255, 180));
  noStroke();
  ellipse(pointRadius * 1.4, 0, 4, 4);
  popMatrix();

  if (shiftRemain < 3.5) {
    float alertPulse = 0.5 + 0.5 * sin(globalTime * 18);
    setUiText(monoFont, 11, CENTER, BOTTOM, color(255, 80, 80, 180 + 75 * alertPulse));
    text("! SHIFT: " + nf(shiftRemain, 1, 1) + "s !", 0, -pointRadius * 3.4);
  }

  rotate(pointHeading + HALF_PI);
  scale(1.0 - abs(bankAngle) * 0.25, 1.0);

  stroke(80, 230, 255, 75);
  strokeWeight(1);
  line(0, -pointRadius * 1.3, 0, -pointRadius * 3.0);
  noStroke();
  fill(120, 240, 255, 180);
  ellipse(0, -pointRadius * 3.0, 3, 3);

  fill(30, 42, 64);
  stroke(70, 110, 170);
  strokeWeight(1.2);
  rect(-pointRadius * 1.3, pointRadius * 0.1, 4, pointRadius * 0.8, 1);
  rect( pointRadius * 1.3 - 4, pointRadius * 0.1, 4, pointRadius * 0.8, 1);

  fill(18, 24, 40);
  stroke(80, 140, 220);
  strokeWeight(1.5);
  beginShape();
  vertex(0, -pointRadius * 1.4);
  vertex(pointRadius * 0.9, -pointRadius * 0.3);
  vertex(pointRadius * 1.2, pointRadius * 0.8);
  vertex(pointRadius * 0.4, pointRadius * 0.6);
  vertex(0, pointRadius * 0.9);
  vertex(-pointRadius * 0.4, pointRadius * 0.6);
  vertex(-pointRadius * 1.2, pointRadius * 0.8);
  vertex(-pointRadius * 0.9, -pointRadius * 0.3);
  endShape(CLOSE);

  float corePulse = 0.5 + 0.5 * sin(globalTime * 8);
  fill(80, 240, 255, 180 + 75 * corePulse);
  ellipse(0, -pointRadius * 0.15, pointRadius * 0.5, pointRadius * 0.7);
  fill(255);
  ellipse(0, -pointRadius * 0.2, pointRadius * 0.2, pointRadius * 0.3);

  fill(255, 60, 60); ellipse(-pointRadius * 1.1, pointRadius * 0.7, 3, 3);
  fill(60, 255, 100); ellipse(pointRadius * 1.1, pointRadius * 0.7, 3, 3);

  if (joyRaw.mag() > 0.05) {
    float flameLen = pointRadius * (1.2 + 0.8 * joyRaw.mag() + 0.3 * sin(globalTime * 45));
    fill(255, 160, 50, 220);
    triangle(-pointRadius * 0.6, pointRadius * 0.6, -pointRadius * 0.3, pointRadius * 0.6, -pointRadius * 0.45, pointRadius * 0.6 + flameLen);
    triangle(pointRadius * 0.3, pointRadius * 0.6, pointRadius * 0.6, pointRadius * 0.6, pointRadius * 0.45, pointRadius * 0.6 + flameLen);
    fill(255, 255, 200);
    triangle(-pointRadius * 0.55, pointRadius * 0.6, -pointRadius * 0.35, pointRadius * 0.6, -pointRadius * 0.45, pointRadius * 0.6 + flameLen * 0.5);
    triangle(pointRadius * 0.35, pointRadius * 0.6, pointRadius * 0.55, pointRadius * 0.6, pointRadius * 0.45, pointRadius * 0.6 + flameLen * 0.5);
  }
  popMatrix();
}

void spawnThrusterPlasma() {
  float ang = pointHeading + PI + random(-0.35, 0.35);
  float px = pointPos.x - cos(pointHeading) * 12, py = pointPos.y - sin(pointHeading) * 12;
  fx.add(new Particle(px, py, cos(ang)*random(2, 5), sin(ang)*random(2, 5),
         color(random(70, 160), random(190, 240), 255), random(7, 14), 0.07));
}

void drawPortal(float x, float y) {
  pushMatrix();
  translate(x, y);
  float pulse = sin(globalTime * 3.5);

  noStroke();
  fill(40, 255, 160, 16 + 8 * pulse);
  ellipse(0, 0, targetRadius * 3.4, targetRadius * 3.4);

  pushMatrix();
  rotate(globalTime * 1.2);
  noFill();
  stroke(70, 255, 180, 210);
  strokeWeight(2.4);
  for (int i = 0; i < 4; i++) arc(0, 0, targetRadius * 2.2, targetRadius * 2.2, i*HALF_PI + 0.1, (i+1)*HALF_PI - 0.2);
  popMatrix();

  pushMatrix();
  rotate(-globalTime * 2.0);
  stroke(140, 255, 220, 180);
  strokeWeight(1.5);
  for (int i = 0; i < 3; i++) arc(0, 0, targetRadius * 1.5, targetRadius * 1.5, i*TWO_PI/3, i*TWO_PI/3 + 1.2);
  popMatrix();

  fill(210, 255, 240);
  noStroke();
  ellipse(0, 0, targetRadius * 0.55, targetRadius * 0.55);
  fill(255);
  ellipse(0, 0, targetRadius * 0.25, targetRadius * 0.25);
  popMatrix();
}

void drawHUD() {
  setUiText(titleFont, 18, LEFT, TOP, color(160, 220, 255));
  text("MISALIGNMENT", 55, 16);

  setUiText(monoFont, 12, LEFT, TOP, color(110, 140, 180));
  text("SECTOR 0" + min(level, winsNeeded) + " / 0" + winsNeeded, 55, 42);

  // Hull HP Bar
  float hpW = 190, hpH = 12, hpX = width/2 - hpW/2, hpY = 22;
  noStroke();
  fill(20, 24, 38);
  rect(hpX, hpY, hpW, hpH, 4);

  color hpCol = (droneHp > 60) ? color(70, 240, 180) : ((droneHp > 30) ? color(255, 190, 60) : color(255, 60, 70));
  if (damageFlash > 0) hpCol = color(255, 255, 255);
  fill(hpCol);
  rect(hpX, hpY, hpW * constrain(displayHp / maxHp, 0, 1), hpH, 4);

  noFill();
  stroke(60, 90, 140, 120);
  strokeWeight(1.2);
  rect(hpX, hpY, hpW, hpH, 4);

  setUiText(monoFont, 11, CENTER, TOP, color(180, 210, 240));
  text("HULL INTEGRITY  " + nf(droneHp, 0, 0) + "%", width/2, hpY + 16);

  // Sector Timer
  float rem = max(0, roundTimeLimit - roundTimer);
  color tc = (rem < 10) ? color(255, 70, 70) : color(255, 200, 90);
  setUiText(titleFont, 18, RIGHT, TOP, tc);
  text(nf(rem, 1, 1) + "s", width - 55, 16);
  setUiText(monoFont, 11, RIGHT, TOP, color(120, 140, 170));
  text("SECTOR TIMER", width - 55, 42);

  noStroke();
  fill(25, 32, 48);
  rect(55, 64, width - 110, 3, 2);
  fill(tc);
  rect(55, 64, (width - 110) * (rem / roundTimeLimit), 3, 2);

  // Polarity Shift Monitor Bar
  float shiftRemain = max(0, scrambleInterval - scrambleTimer);
  float shiftPct = constrain(scrambleTimer / scrambleInterval, 0, 1);
  float barY = 90, barW = width - 110, barX = 55;
  boolean imminent = (shiftRemain <= 3.5);

  color shiftColor = imminent ? color(255, 60, 70) : ((shiftRemain < 7.0) ? color(255, 190, 60) : color(80, 190, 255));
  float flashAlpha = imminent ? (180 + 75 * sin(globalTime * 18)) : 220;

  setUiText(monoFont, 11, LEFT, BOTTOM, color(shiftColor, flashAlpha));
  text(imminent ? ("⚠ WARNING: POLARITY SHIFT IN " + nf(shiftRemain, 1, 1) + "s") : ("AXIS DRIFT STABILITY // NEXT SHIFT: " + nf(shiftRemain, 1, 1) + "s"), barX, barY - 4);

  setUiText(monoFont, 11, RIGHT, BOTTOM, color(shiftColor, flashAlpha));
  text(nf((1.0 - shiftPct) * 100, 0, 0) + "% SYNC", barX + barW, barY - 4);

  fill(20, 26, 42);
  rect(barX, barY, barW, 4, 2);
  fill(shiftColor, flashAlpha);
  rect(barX, barY, barW * (1.0 - shiftPct), 4, 2);

  // Bottom Telemetry
  drawGauge(playAreaX + 80, height - 52, "P2 [POTENTIOMETER]", calibrationAngle, true);
  drawGauge(playAreaX + 220, height - 52, "P1 [JOYSTICK]", atan2(joyRaw.y, joyRaw.x), false);

  setUiText(monoFont, 12, RIGHT, BOTTOM, color(255, 215, 110));
  text("TEAM SCORE: " + nf(teamTotalScore, 0, 0) + " PTS", width - 55, height - 54);
  setUiText(monoFont, 11, RIGHT, BOTTOM, color(140, 170, 210));
  text("P1 PILOT: " + nf(p1Points, 0, 0) + "  |  P2 NAV: " + nf(p2Points, 0, 0), width - 55, height - 34);
}

void drawGauge(float cx, float cy, String label, float angle, boolean isKnob) {
  setUiText(monoFont, 11, CENTER, BOTTOM, color(130, 160, 200));
  text(label, cx, cy - 36);

  noFill();
  stroke(60, 100, 160, 130);
  strokeWeight(1.8);
  ellipse(cx, cy, 58, 58);

  if (isKnob) {
    float gx = cx + cos(angle) * 23, gy = cy + sin(angle) * 23;
    stroke(120, 220, 255);
    strokeWeight(2.5);
    line(cx, cy, gx, gy);
    fill(120, 220, 255);
    ellipse(gx, gy, 6, 6);
  } else {
    stroke(255, 170, 80, 80);
    strokeWeight(1);
    line(cx - 23, cy, cx + 23, cy);
    line(cx, cy - 23, cy, cy + 23);
    fill(255, 180, 90);
    noStroke();
    ellipse(cx + joyRaw.x * 21, cy + joyRaw.y * 21, 8, 8);
  }
}

void drawRoundOverlay() {
  fill(5, 7, 18, 220);
  noStroke();
  rect(0, 0, width, height);

  setUiText(titleFont, 32, CENTER, CENTER, color(120, 255, 190));
  text("SECTOR VECTOR CLEARED", width/2, 130);

  drawScoreCard(width/2 - 165, 200, "P1 (PILOT)", p1RoundPoints, lastP1Accuracy, color(255, 170, 90));
  drawScoreCard(width/2 + 15, 200, "P2 (NAVIGATOR)", p2RoundPoints, lastP2Accuracy, color(100, 200, 255));

  setUiText(monoFont, 14, CENTER, CENTER, color(70, 240, 180));
  text("HULL FIELD REPAIRED (+25%)", width/2, height - 110);
  setUiText(monoFont, 15, CENTER, CENTER, color(255, 180 + 75 * sin(globalTime * 6)));
  text("ALIGNING NEXT PROTOCOL...", width/2, height - 70);
}

void drawScoreCard(float x, float y, String title, float pts, float acc, color col) {
  fill(14, 18, 34, 240);
  stroke(col, 170);
  strokeWeight(2);
  rect(x, y, 150, 160, 8);

  setUiText(monoFont, 13, CENTER, TOP, col);
  text(title, x + 75, y + 16);
  setUiText(titleFont, 22, CENTER, TOP, col);
  text("+" + nf(pts, 0, 0), x + 75, y + 54);
  setUiText(monoFont, 14, CENTER, TOP, color(220));
  text(nf(acc * 100, 0, 0) + "% ACC", x + 75, y + 104);
}

void drawTerminalOverlay(boolean win) {
  fill(win ? color(5, 12, 22, 235) : color(22, 5, 8, 235));
  noStroke();
  rect(0, 0, width, height);

  setUiText(titleFont, 34, CENTER, CENTER, win ? color(120, 255, 190) : color(255, 80, 80));
  text(win ? "MISSION SUCCESS" : "HULL BREACH - SIGNAL LOST", width/2, 110);

  setUiText(monoFont, 18, CENTER, CENTER, color(255, 220, 110));
  text("TEAM TOTAL SCORE: " + nf(teamTotalScore, 0, 0) + " PTS", width/2, 165);
  setUiText(monoFont, 14, CENTER, CENTER, color(255, 180, 90));
  text("P1 PILOT: " + nf(p1Points, 0, 0) + " PTS", width/2 - 120, 205);
  setUiText(monoFont, 14, CENTER, CENTER, color(120, 200, 255));
  text("P2 NAV  : " + nf(p2Points, 0, 0) + " PTS", width/2 + 120, 205);

  float boxW = 380, boxH = 170, boxX = width/2 - boxW/2, boxY = 250;
  fill(16, 22, 42, 240);
  stroke(70, 130, 210, 160);
  strokeWeight(2);
  rect(boxX, boxY, boxW, boxH, 8);

  if (!scoreRecorded) {
    setUiText(monoFont, 13, CENTER, TOP, color(180, 210, 255));
    text("ENTER TEAM INITIALS / TAG:", width/2, boxY + 20);
    fill(10, 14, 28);
    stroke(100, 180, 255);
    rect(width/2 - 120, boxY + 54, 240, 38, 4);

    float blink = (sin(globalTime * 8) > 0) ? 1 : 0;
    setUiText(titleFont, 20, CENTER, CENTER, color(255, 230, 120));
    text(playerInputName + (blink > 0 ? "_" : ""), width/2, boxY + 72);
    setUiText(monoFont, 12, CENTER, TOP, color(130, 160, 200));
    text("[ TYPE & PRESS ENTER TO SAVE ]", width/2, boxY + 115);
  } else {
    setUiText(monoFont, 15, CENTER, CENTER, color(100, 255, 180));
    text("SCORE RECORDED TO ARCHIVE!", width/2, boxY + 65);
    setUiText(monoFont, 13, CENTER, CENTER, color(200, 220, 255));
    text("PRESS 'L' TO VIEW LEADERBOARD", width/2, boxY + 105);
  }

  setUiText(monoFont, 13, CENTER, CENTER, color(255, 200, 90));
  text("[ PRESS 'R' TO REBOOT MISSION | 'L' FOR LEADERBOARD ]", width/2, height - 55);
}

void drawLeaderboardScreen() {
  fill(6, 9, 20);
  noStroke();
  rect(0, 0, width, height);

  setUiText(titleFont, 32, CENTER, TOP, color(140, 220, 255));
  text("MISSION LEADERBOARD", width/2, 45);
  setUiText(monoFont, 13, CENTER, TOP, color(120, 150, 190));
  text("ACADEMY SQUAD ARCHIVE (REAL RUNS ONLY)", width/2, 90);

  float tW = 560, tH = 430, tX = width/2 - tW/2, tY = 125;
  fill(14, 18, 34, 240);
  stroke(50, 90, 150, 140);
  strokeWeight(2);
  rect(tX, tY, tW, tH, 8);

  if (leaderboard.isEmpty()) {
    setUiText(monoFont, 15, CENTER, CENTER, color(140, 180, 230));
    text("NO MISSION RECORDS ARCHIVED YET", width/2, tY + tH/2 - 16);
    setUiText(monoFont, 12, CENTER, CENTER, color(100, 130, 175));
    text("Complete a run to register your squad on the board!", width/2, tY + tH/2 + 16);
  } else {
    setUiText(monoFont, 13, LEFT, TOP, color(130, 180, 255));
    text("RANK", tX + 30, tY + 20);
    text("TEAM TAG", tX + 110, tY + 20);
    text("SECTOR", tX + 280, tY + 20);
    text("SCORE", tX + 430, tY + 20);

    stroke(50, 80, 130, 100);
    line(tX + 20, tY + 45, tX + tW - 20, tY + 45);

    int maxRows = min(8, leaderboard.size());
    for (int i = 0; i < maxRows; i++) {
      ScoreEntry se = leaderboard.get(i);
      float rowY = tY + 60 + i * 42;
      color rowCol = (i == 0) ? color(255, 215, 90) : ((i == 1) ? color(220, 230, 255) : ((i == 2) ? color(240, 160, 100) : color(180, 200, 230)));
      setUiText(monoFont, 14, LEFT, TOP, rowCol);
      text("#0" + (i + 1), tX + 30, rowY);
      text(se.teamName, tX + 110, rowY);
      text("SEC 0" + se.sector, tX + 280, rowY);
      text(nf(se.score, 0, 0) + " PTS", tX + 430, rowY);
    }
  }

  setUiText(monoFont, 12, CENTER, CENTER, color(255, 200, 90));
  text("[ 'R' NEW ROUND | 'C' CLEAR ARCHIVE | 'ESC' / 'L' RETURN ]", width/2, height - 55);
}

void keyPressed() {
  if (state == GameState.GAME_WIN || state == GameState.GAME_LOSE) {
    if (!scoreRecorded) {
      if (key == BACKSPACE && playerInputName.length() > 0) {
        playerInputName = playerInputName.substring(0, playerInputName.length() - 1);
      } else if ((key == ENTER || key == RETURN) && playerInputName.trim().length() > 0) {
        saveScore(playerInputName.trim().toUpperCase(), (int)teamTotalScore, level);
        scoreRecorded = true;
        state = GameState.LEADERBOARD;
      } else if (((key >= 'a' && key <= 'z') || (key >= 'A' && key <= 'Z') || (key >= '0' && key <= '9') || key == ' ' || key == '-') && playerInputName.length() < MAX_NAME_LEN) {
        playerInputName += str(key).toUpperCase();
      }
    }
    if (key == 'r' || key == 'R') restartGame();
    if (key == 'l' || key == 'L') state = GameState.LEADERBOARD;
  } else if (state == GameState.LEADERBOARD) {
    if (key == 'c' || key == 'C') clearLeaderboard();
    if (key == 'r' || key == 'R') restartGame();
    if (key == 'l' || key == 'L' || key == ESC) {
      key = 0;
      state = (droneHp <= 0) ? GameState.GAME_LOSE : GameState.GAME_WIN;
    }
  }
}

void restartGame() {
  level = 1;
  droneHp = maxHp;
  displayHp = maxHp;
  damageFlash = 0;
  scrambleCount = 0;
  p1Points = 0;
  p2Points = 0;
  teamTotalScore = 0;
  cameraZoom = 1.0;
  cameraTarget = 1.0;
  playerInputName = "";
  scoreRecorded = false;
  stopThrusterAudio();
  newRound();
  randomizeHiddenRotation();
  state = GameState.PLAYING;
}

void buildMaze(int lvl) {
  int cols = 4 + min(lvl, 2), rows = 3 + min(lvl, 2);
  int gw = cols * 2 + 1, gh = rows * 2 + 1;
  boolean[][] grid = new boolean[gw][gh], visited = new boolean[gw][gh];
  for (int x = 0; x < gw; x++) for (int y = 0; y < gh; y++) grid[x][y] = true;

  ArrayList<int[]> stack = new ArrayList<int[]>();
  grid[1][1] = false; visited[1][1] = true; stack.add(new int[]{1, 1});

  int[][] dirs = {{2, 0}, {-2, 0}, {0, 2}, {0, -2}};
  while (!stack.isEmpty()) {
    int[] cur = stack.get(stack.size() - 1);
    ArrayList<int[]> neighbors = new ArrayList<int[]>();
    for (int[] d : dirs) {
      int nx = cur[0] + d[0], ny = cur[1] + d[1];
      if (nx > 0 && nx < gw - 1 && ny > 0 && ny < gh - 1 && !visited[nx][ny]) neighbors.add(new int[]{nx, ny});
    }
    if (!neighbors.isEmpty()) {
      int[] next = neighbors.get((int)random(neighbors.size()));
      grid[(cur[0] + next[0]) / 2][(cur[1] + next[1]) / 2] = false;
      grid[next[0]][next[1]] = false;
      visited[next[0]][next[1]] = true;
      stack.add(new int[]{next[0], next[1]});
    } else {
      stack.remove(stack.size() - 1);
    }
  }

  for (int x = 1; x < gw - 1; x++) {
    for (int y = 1; y < gh - 1; y++) {
      if ((x % 2 != y % 2) && grid[x][y] && random(1) < 0.20) grid[x][y] = false;
    }
  }

  float wallW = playAreaW / (3.0 * cols + 1.0), pathW = 2.0 * wallW;
  float wallH = playAreaH / (3.0 * rows + 1.0), pathH = 2.0 * wallH;
  float[] colX = new float[gw], colW = new float[gw], rowY = new float[gh], rowH = new float[gh];

  float curX = 0;
  for (int x = 0; x < gw; x++) {
    colX[x] = curX; colW[x] = (x % 2 == 0) ? wallW : pathW; curX += colW[x];
  }
  float curY = 0;
  for (int y = 0; y < gh; y++) {
    rowY[y] = curY; rowH[y] = (y % 2 == 0) ? wallH : pathH; curY += rowH[y];
  }

  cellW = pathW; cellH = pathH;
  walls.clear(); wallNodes.clear();

  for (int x = 0; x < gw; x++) {
    for (int y = 0; y < gh; y++) {
      if (grid[x][y]) {
        walls.add(new Wall(colX[x], rowY[y], colW[x], rowH[y]));
        if (x % 2 == 0 && y % 2 == 0 && (x > 0 && x < gw - 1 && y > 0 && y < gh - 1)) {
          wallNodes.add(new PVector(colX[x] + colW[x] * 0.5, rowY[y] + rowH[y] * 0.5));
        }
      }
    }
  }

  startPos.set(playAreaX + colX[1] + colW[1] * 0.5, playAreaY + rowY[1] + rowH[1] * 0.5);
  pointPos.set(startPos.x, startPos.y);
  targetPos.set(playAreaX + colX[gw - 2] + colW[gw - 2] * 0.5, playAreaY + rowY[gh - 2] + rowH[gh - 2] * 0.5);
}

void newRound() {
  buildMaze(min(level, 2));
  pointVel.set(0, 0); knockback.set(0, 0);
  pointHeading = 0; targetHeading = 0; bankAngle = 0; recoilStun = 0; shieldPulse = 1.0; damageFlash = 0;
  scrambleInterval = max(10.0, 25.0 - level * 3.0);
  roundTimeLimit   = max(45.0, 70.0 - level * 6.0);
  roundTimer = 0; scrambleTimer = 0; lastWarningSecond = -1; zapCooldown = 0; zapFlash = 0;
  navAccuracySum = 0; navAccuracySamples = 0; sectorWallHits = 0;
}

void randomizeHiddenRotation() { hiddenRotation = random(0, TWO_PI); }

float circularAngleDiff(float a, float b) {
  float d = a - b;
  while (d > PI)  d -= TWO_PI;
  while (d < -PI) d += TWO_PI;
  return d;
}

float lerpAngle(float a, float b, float t) { return a + circularAngleDiff(b, a) * t; }

PVector rotateVector(PVector v, float ang) {
  float c = cos(ang), s = sin(ang);
  return new PVector(v.x * c - v.y * s, v.x * s + v.y * c);
}

void updateRoundWin() {
  roundWinTimer += 1.0 / frameRate;
  cameraTarget = 1.0;
  if (roundWinTimer > 2.6) {
    newRound();
    randomizeHiddenRotation();
    state = GameState.PLAYING;
  }
}

void initAudioSynthesizer() {
  try {
    sndZap      = generateZapClip();
    sndPortal   = generatePortalClip();
    sndScramble = generateScrambleClip();
    sndBeep     = generateBeepClip();
    sndExplode  = generateExplosionClip();
    sndAmbient  = generateAmbientClip();
    sndThruster = generateThrusterClip();
  } catch (Exception e) {}
}

void playAudio(Clip c) {
  if (c != null) {
    try { c.stop(); c.setFramePosition(0); c.start(); } catch (Exception e) {}
  }
}

void playLoopAudio(Clip c) {
  if (c != null) {
    try { c.stop(); c.setFramePosition(0); c.loop(Clip.LOOP_CONTINUOUSLY); } catch (Exception e) {}
  }
}

void updateThrusterAudio() {
  boolean shouldBurn = (state == GameState.PLAYING && joyRaw.mag() > 0.08);
  if (shouldBurn) {
    if (!thrusterPlaying && sndThruster != null) {
      try { sndThruster.setFramePosition(0); sndThruster.loop(Clip.LOOP_CONTINUOUSLY); thrusterPlaying = true; } catch (Exception e) {}
    }
  } else stopThrusterAudio();
}

void stopThrusterAudio() {
  if (thrusterPlaying && sndThruster != null) {
    try { sndThruster.stop(); } catch (Exception e) {}
    thrusterPlaying = false;
  }
}

Clip generateAmbientClip() {
  int rate = 22050, samples = rate * 4;
  float[] raw = new float[samples];
  float[] mid = {146.83, 220, 261.63, 293.66, 261.63, 220, 174.61, 220, 196, 233.08, 293.66, 349.23, 329.63, 261.63, 220, 146.83};
  float[] bass = {73.42, 73.42, 73.42, 73.42, 87.31, 87.31, 87.31, 87.31, 98, 98, 98, 98, 110, 110, 110, 110};

  for (int i = 0; i < samples; i++) {
    float t = (float)i / rate, st = t % 0.25;
    int step = min(15, (int)(t / 0.25));
    float env = min(1.0, st / 0.015) * exp(-st * 6.5);
    float lead = (sin(TWO_PI * mid[step] * t) * 0.85 + sin(TWO_PI * mid[step] * 2 * t) * 0.15) * env * 0.16;
    float b = sin(TWO_PI * bass[step] * t) * min(1.0, st / 0.015) * exp(-st * 4.0) * 0.14;
    raw[i] = lead + b + sin(TWO_PI * 220 * t) * 0.035 + sin(TWO_PI * 261.63 * t) * 0.025;
  }
  crossfade(raw, 400);
  return buildFloatClip(raw, rate);
}

Clip generateThrusterClip() {
  int rate = 22050, samples = (int)(rate * 0.5);
  float[] raw = new float[samples];
  float smoothNoise = 0;
  for (int i = 0; i < samples; i++) {
    float t = (float)i / rate;
    smoothNoise = lerp(smoothNoise, random(-1, 1), 0.25);
    raw[i] = ((sin(TWO_PI * 72 * t) * 0.55 + sin(TWO_PI * 108 * t) * 0.25) * 0.6 + smoothNoise * 0.4) * 0.35;
  }
  crossfade(raw, 800);
  return buildFloatClip(raw, rate);
}

Clip generateZapClip() {
  int rate = 22050, samples = (int)(rate * 0.18);
  float[] raw = new float[samples];
  for (int i = 0; i < samples; i++) {
    float t = (float)i / samples;
    raw[i] = (1.0 - t) * (sin(TWO_PI * lerp(320, 60, t) * i / rate) * 0.6 + random(-1, 1) * 0.4) * 0.94;
  }
  return buildFloatClip(raw, rate);
}

Clip generatePortalClip() {
  int rate = 22050, samples = (int)(rate * 0.45);
  float[] notes = { 523.25, 659.25, 783.99, 1046.5 }, raw = new float[samples];
  for (int i = 0; i < samples; i++) {
    float t = (float)i / samples;
    float f = notes[min(notes.length - 1, (int)(t * notes.length))];
    raw[i] = (sin(TWO_PI * f * i / rate) * 0.7 + sin(TWO_PI * f * 2.0 * i / rate) * 0.3) * (1.0 - t) * 0.90;
  }
  return buildFloatClip(raw, rate);
}

Clip generateScrambleClip() {
  int rate = 22050, samples = (int)(rate * 0.35);
  float[] raw = new float[samples];
  for (int i = 0; i < samples; i++) {
    float t = (float)i / samples, f = (sin(TWO_PI * 14.0 * t) > 0) ? 680 : 440;
    raw[i] = ((sin(TWO_PI * f * i / rate) > 0) ? 0.7 : -0.7) * (1.0 - t * 0.5) * 0.86;
  }
  return buildFloatClip(raw, rate);
}

Clip generateBeepClip() {
  int rate = 22050, samples = (int)(rate * 0.08);
  float[] raw = new float[samples];
  for (int i = 0; i < samples; i++) raw[i] = sin(TWO_PI * 980.0 * i / rate) * (1.0 - (float)i / samples) * 0.94;
  return buildFloatClip(raw, rate);
}

Clip generateExplosionClip() {
  int rate = 22050, samples = (int)(rate * 0.65);
  float[] raw = new float[samples];
  float smoothNoise = 0;
  for (int i = 0; i < samples; i++) {
    float t = (float)i / samples;
    smoothNoise = lerp(smoothNoise, random(-1, 1), 0.35);
    raw[i] = (sin(TWO_PI * lerp(90, 25, t) * i / rate) * 0.5 + smoothNoise * 0.5) * (1.0 - t) * (1.0 - t) * 0.99;
  }
  return buildFloatClip(raw, rate);
}

void crossfade(float[] raw, int fadeLen) {
  int s = raw.length;
  for (int i = 0; i < fadeLen; i++) {
    float f = (float)i / fadeLen;
    raw[i] = raw[i] * f + raw[s - fadeLen + i] * (1.0 - f);
  }
}

Clip buildFloatClip(float[] raw, int sampleRate) {
  byte[] data = new byte[raw.length];
  for (int i = 0; i < raw.length; i++) data[i] = (byte)constrain((int)(128 + raw[i] * 127), 0, 255);
  try {
    AudioFormat format = new AudioFormat((float)sampleRate, 8, 1, false, false);
    Clip clip = (Clip) AudioSystem.getLine(new DataLine.Info(Clip.class, format));
    clip.open(format, data, 0, data.length);
    return clip;
  } catch (Exception e) { return null; }
}

void loadLeaderboard() {
  leaderboard.clear();
  try {
    File f = new File(sketchPath("misalignment_scores.json"));
    if (f.exists()) {
      JSONArray arr = loadJSONArray("misalignment_scores.json");
      for (int i = 0; i < arr.size(); i++) {
        JSONObject obj = arr.getJSONObject(i);
        leaderboard.add(new ScoreEntry(obj.getString("team"), obj.getInt("score"), obj.getInt("sector")));
      }
    }
  } catch (Exception e) {}
  sortLeaderboard();
}

void saveScore(String team, int score, int sector) {
  if (team != null && team.trim().length() > 0) {
    leaderboard.add(new ScoreEntry(team.trim().toUpperCase(), score, sector));
    sortLeaderboard();
    persistLeaderboard();
  }
}

void clearLeaderboard() {
  leaderboard.clear();
  try {
    File f = new File(sketchPath("misalignment_scores.json"));
    if (f.exists()) f.delete();
  } catch (Exception e) {}
}

void persistLeaderboard() {
  JSONArray arr = new JSONArray();
  for (int i = 0; i < min(10, leaderboard.size()); i++) {
    ScoreEntry se = leaderboard.get(i);
    JSONObject obj = new JSONObject();
    obj.setString("team", se.teamName);
    obj.setInt("score", se.score);
    obj.setInt("sector", se.sector);
    arr.setJSONObject(i, obj);
  }
  saveJSONArray(arr, "misalignment_scores.json");
}

void sortLeaderboard() {
  leaderboard.sort((a, b) -> Integer.compare(b.score, a.score));
}

void setUiText(PFont f, float sz, int alignX, int alignY, color col) {
  if (f != null) textFont(f);
  textSize(sz);
  textAlign(alignX, alignY);
  fill(col);
}

void spawnBurst(float x, float y, int n, color c, float spd) {
  for (int i = 0; i < n; i++) {
    float a = random(TWO_PI), s = random(1.5, spd);
    fx.add(new Particle(x, y, cos(a)*s, sin(a)*s, c, random(4, 9), random(0.02, 0.045)));
  }
}

void updateFX() {
  for (int i = fx.size() - 1; i >= 0; i--) {
    Particle p = fx.get(i);
    p.update();
    if (p.dead()) fx.remove(i);
  }
}

void drawVFX() {
  noStroke();
  for (Particle p : fx) p.render();
}

class ScoreEntry {
  String teamName; int score, sector;
  ScoreEntry(String t, int s, int sec) { teamName = t; score = s; sector = sec; }
}

class Wall {
  float x, y, w, h;
  Wall(float x, float y, float w, float h) { this.x = x; this.y = y; this.w = w; this.h = h; }
}

class Particle {
  PVector pos, vel; color c; float size, life = 1.0, decay;
  Particle(float x, float y, float vx, float vy, color c, float size, float decay) {
    this.pos = new PVector(x, y); this.vel = new PVector(vx, vy);
    this.c = c; this.size = size; this.decay = decay;
  }
  void update() { pos.add(vel); vel.mult(0.92); life -= decay; }
  boolean dead() { return life <= 0; }
  void render() { fill(red(c), green(c), blue(c), life * 240); ellipse(pos.x, pos.y, size * life, size * life); }
}

class Star {
  float x, y, speed, size;
  Star() { x = random(width); y = random(height * 0.72); speed = random(0.1, 0.45); size = random(1, 2.2); }
  void render() { y = (y + speed) % (height * 0.72); fill(180, 210, 255, 100 + 80 * sin(globalTime * 2 + x)); ellipse(x, y, size, size); }
}
