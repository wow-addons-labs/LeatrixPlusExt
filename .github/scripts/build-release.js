#!/usr/bin/env node
'use strict';

// 构建 Release 用的插件目录：
//   - 只收集 .toc 和 .lua 文件，其余文件（README、docs 等）不进入构建产物；
//   - 每个 .lua 文件都会删除注释，字符串里的 -- 和长字符串内容保持原样；
//   - 输出到 dist/<插件名>/，保持原来的相对路径，可直接压缩后放进 Interface/AddOns。
//
// 用法：node .github/scripts/build-release.js

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DIST = path.join(ROOT, 'dist');

const SKIP_DIRS = new Set(['.git', 'dist', 'node_modules']);

// ---------------------------------------------------------------------------
// Lua 注释剥离
// ---------------------------------------------------------------------------

// 判断 i 处是否是长括号开头（[[ / [=[ / [==[ ...），返回等号数量，不是则返回 -1
function longBracketLevel(src, i) {
    if (src[i] !== '[') return -1;
    let j = i + 1;
    while (src[j] === '=') j += 1;
    if (src[j] !== '[') return -1;
    return j - i - 1;
}

function stripLuaComments(src) {
    const out = [];
    let pendingWs = '';
    let lineHasCode = false;
    let i = 0;
    const n = src.length;

    function flushWs() {
        if (pendingWs) {
            out.push(pendingWs);
            pendingWs = '';
        }
    }

    function emit(text) {
        flushWs();
        out.push(text);
    }

    function newlineLength(pos) {
        return (src[pos] === '\r' && src[pos + 1] === '\n') ? 2 : 1;
    }

    while (i < n) {
        const ch = src[i];

        // 换行：丢弃行尾空白，行内代码状态归零
        if (ch === '\n' || ch === '\r') {
            const len = newlineLength(i);
            pendingWs = '';
            out.push(src.slice(i, i + len));
            i += len;
            lineHasCode = false;
            continue;
        }

        // 注释
        if (ch === '-' && src[i + 1] === '-') {
            pendingWs = '';
            i += 2;

            const level = longBracketLevel(src, i);
            if (level >= 0) {
                // --[[ ... ]] / --[==[ ... ]==]
                const closing = ']' + '='.repeat(level) + ']';
                const end = src.indexOf(closing, i + level + 2);
                const standalone = !lineHasCode;
                i = end < 0 ? n : end + closing.length;

                if (standalone) {
                    // 整行只有注释：连同该行缩进和换行一起删掉
                    let j = i;
                    while (src[j] === ' ' || src[j] === '\t') j += 1;
                    if (j >= n) {
                        i = j;
                    } else if (src[j] === '\n' || src[j] === '\r') {
                        i = j + newlineLength(j);
                        lineHasCode = false;
                    } else {
                        i = j;
                    }
                } else {
                    // 行内注释被删除后留一个空格，避免前后 token 粘在一起
                    pendingWs = ' ';
                }
                continue;
            }

            // -- 行注释
            while (i < n && src[i] !== '\n' && src[i] !== '\r') i += 1;
            if (!lineHasCode) {
                // 整行只有注释：连同换行一起删掉
                if (i < n) {
                    i += newlineLength(i);
                }
                lineHasCode = false;
            }
            continue;
        }

        // 短字符串（'...' / "..."），处理反斜杠转义
        if (ch === '"' || ch === "'") {
            let j = i + 1;
            while (j < n) {
                const c = src[j];
                if (c === '\\') {
                    j += 2;
                    continue;
                }
                if (c === ch) {
                    j += 1;
                    break;
                }
                if (c === '\n' || c === '\r') {
                    j += 1;
                    break;
                }
                j += 1;
            }
            emit(src.slice(i, j));
            lineHasCode = true;
            i = j;
            continue;
        }

        // 长字符串 [[ ... ]] / [=[ ... ]=]，内容里的 -- 不能当成注释
        if (ch === '[') {
            const level = longBracketLevel(src, i);
            if (level >= 0) {
                const closing = ']' + '='.repeat(level) + ']';
                const end = src.indexOf(closing, i + level + 2);
                const j = end < 0 ? n : end + closing.length;
                emit(src.slice(i, j));
                lineHasCode = true;
                i = j;
                continue;
            }
        }

        if (ch === ' ' || ch === '\t') {
            pendingWs += ch;
            i += 1;
            continue;
        }

        flushWs();
        out.push(ch);
        lineHasCode = true;
        i += 1;
    }

    return out.join('');
}

// ---------------------------------------------------------------------------
// 收集与输出
// ---------------------------------------------------------------------------

function walk(dir, files) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
        const full = path.join(dir, entry.name);
        if (entry.isDirectory()) {
            if (SKIP_DIRS.has(entry.name)) continue;
            walk(full, files);
        } else if (entry.isFile()) {
            files.push(full);
        }
    }
    return files;
}

function main() {
    const tocs = fs.readdirSync(ROOT).filter((name) => name.toLowerCase().endsWith('.toc'));
    if (tocs.length !== 1) {
        throw new Error(`根目录应当只有 1 个 .toc 文件，实际找到 ${tocs.length} 个`);
    }

    const tocName = tocs[0];
    const addonName = path.basename(tocName, path.extname(tocName));
    const outDir = path.join(DIST, addonName);

    fs.rmSync(DIST, { recursive: true, force: true });
    fs.mkdirSync(outDir, { recursive: true });

    let luaCount = 0;
    let tocCount = 0;
    let beforeBytes = 0;
    let afterBytes = 0;

    for (const file of walk(ROOT, [])) {
        const ext = path.extname(file).toLowerCase();
        if (ext !== '.lua' && ext !== '.toc') continue;

        const rel = path.relative(ROOT, file);
        const dest = path.join(outDir, rel);
        fs.mkdirSync(path.dirname(dest), { recursive: true });

        if (ext === '.lua') {
            const source = fs.readFileSync(file, 'utf8');
            const stripped = stripLuaComments(source);
            beforeBytes += Buffer.byteLength(source, 'utf8');
            afterBytes += Buffer.byteLength(stripped, 'utf8');
            fs.writeFileSync(dest, stripped, 'utf8');
            luaCount += 1;
        } else {
            fs.copyFileSync(file, dest);
            tocCount += 1;
        }
    }

    if (!fs.existsSync(path.join(outDir, tocName))) {
        throw new Error('构建产物里缺少 .toc 文件');
    }
    if (luaCount === 0) {
        throw new Error('构建产物里没有任何 .lua 文件');
    }

    const saved = beforeBytes - afterBytes;
    const percent = beforeBytes ? ((saved / beforeBytes) * 100).toFixed(1) : '0.0';
    console.log(`构建完成：${path.relative(ROOT, outDir)}`);
    console.log(`  .lua ${luaCount} 个，.toc ${tocCount} 个`);
    console.log(`  注释与空白减少 ${saved} 字节（${percent}%），剩余 ${afterBytes} 字节`);
}

if (require.main === module) {
    main();
}

module.exports = { stripLuaComments };
