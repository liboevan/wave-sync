const {DatabaseSync} = require('node:sqlite');
const path = require('path');

const dbPath = process.argv[2] || 'C:/Users/evan/AppData/Local/waveterm/Data/db/waveterm.db';
const outDir = process.argv[3] || 'C:/Users/evan/AppData/Local/waveterm/wave-sync-export';

const fs = require('fs');
if (!fs.existsSync(outDir)) fs.mkdirSync(outDir, {recursive: true});

const SYNC_TABLES = ['db_block', 'db_client', 'db_layout', 'db_mainserver', 'db_tab', 'db_window', 'db_workspace'];

let db;
try {
  db = new DatabaseSync(dbPath, {readOnly: true, allowExtendedKeys: true, timeout: 3000});
} catch (e) {
  console.error(`FATAL: cannot open DB (locked by Wave?): ${e.message}`);
  process.exit(1);
}

for (const table of SYNC_TABLES) {
  try {
    const rows = db.prepare(`SELECT oid, version, data FROM "${table}"`).all();
    const decoded = rows.map(r => {
      let jsonStr = '';
      if (r.data) {
        if (typeof r.data === 'string') {
          jsonStr = r.data;
        } else {
          const obj = r.data;
          const keys = Object.keys(obj).map(Number).sort((a,b) => a - b);
          jsonStr = keys.map(k => String.fromCharCode(obj[k])).join('');
        }
      }
      let parsed;
      try { parsed = JSON.parse(jsonStr); } catch(e) { parsed = jsonStr; }
      return {oid: r.oid, version: r.version, data: parsed};
    });

    const fileName = table.replace('db_', '') + '.json';
    const filePath = path.join(outDir, fileName);
    fs.writeFileSync(filePath, JSON.stringify(decoded, null, 2), 'utf8');
    console.log(`${table}: ${rows.length} rows -> ${fileName}`);
  } catch(e) {
    console.error(`${table}: error - ${e.message}`);
  }
}

if (db) db.close();
console.log('Done. Output:', outDir);
