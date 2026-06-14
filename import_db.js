const {DatabaseSync} = require('node:sqlite');
const fs = require('fs');
const path = require('path');

const dbPath = process.argv[2] || 'C:/Users/evan/AppData/Local/waveterm/Data/db/waveterm.db';
const importDir = process.argv[3] || 'C:/Users/evan/AppData/Local/waveterm/wave-sync-export';

const TABLE_MAP = {
  'block.json': 'db_block',
  'client.json': 'db_client',
  'layout.json': 'db_layout',
  'mainserver.json': 'db_mainserver',
  'tab.json': 'db_tab',
  'window.json': 'db_window',
  'workspace.json': 'db_workspace',
};

let db;
try {
  db = new DatabaseSync(dbPath, {allowExtendedKeys: true, timeout: 3000});
} catch (e) {
  console.error(`FATAL: cannot open DB (locked by Wave?): ${e.message}`);
  process.exit(1);
}
let totalInserted = 0, totalUpdated = 0, totalSkipped = 0;

for (const [fileName, tableName] of Object.entries(TABLE_MAP)) {
  const filePath = path.join(importDir, fileName);
  if (!fs.existsSync(filePath)) {
    console.log(`${fileName}: not found, skipping`);
    continue;
  }

  const rows = JSON.parse(fs.readFileSync(filePath, 'utf8'));
  const insertStmt = db.prepare(`INSERT INTO "${tableName}" (oid, version, data) VALUES (?, ?, ?)`);
  const updateStmt = db.prepare(`UPDATE "${tableName}" SET version = ?, data = ? WHERE oid = ?`);
  const checkStmt = db.prepare(`SELECT version FROM "${tableName}" WHERE oid = ?`);

  let inserted = 0, updated = 0, skipped = 0;

  for (const row of rows) {
    let jsonData;
    if (typeof row.data === 'string') {
      jsonData = row.data;
    } else {
      jsonData = JSON.stringify(row.data);
    }

    const existing = checkStmt.get(row.oid);
    if (!existing) {
      insertStmt.run(row.oid, row.version, jsonData);
      inserted++;
    } else if (row.version > existing.version) {
      updateStmt.run(row.version, jsonData, row.oid);
      updated++;
    } else {
      skipped++;
    }
  }

  totalInserted += inserted;
  totalUpdated += updated;
  totalSkipped += skipped;
  console.log(`${tableName}: +${inserted} inserted, ${updated} updated, ${skipped} skipped`);
}

db.close();
console.log(`\nTotal: +${totalInserted} inserted, ${totalUpdated} updated, ${totalSkipped} skipped`);
