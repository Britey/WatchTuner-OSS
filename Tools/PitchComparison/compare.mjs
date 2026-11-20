import fs from 'node:fs';
import {PitchDetector} from 'pitchy';
const rows = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
for (const row of rows) {
 const detector = PitchDetector.forFloat32Array(row.input.length);
 detector.minVolumeAbsolute = 0;
 const [hz, clarity] = detector.findPitch(Float32Array.from(row.input), row.sample_rate);
 row.pitchy = hz > 0 && clarity >= 0.8 ? hz : null;
 row.pitchy_raw = hz; row.pitchy_clarity = clarity;
 delete row.input;
}
fs.writeFileSync(process.argv[3], JSON.stringify(rows, null, 2));
