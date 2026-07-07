import { mkdtemp, writeFile, chmod, readFile, readdir, mkdir, copyFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import test from 'node:test'
import assert from 'node:assert/strict'

const execFileAsync = promisify(execFile)
const scriptDir = dirname(fileURLToPath(import.meta.url))
const promqlScript = join(scriptDir, 'promql.sh')
const logqlScript = join(scriptDir, 'logql.sh')
const incidentScript = join(scriptDir, 'incident.sh')
const reportScript = join(scriptDir, 'report.sh')

// A curl stand-in that records its args and returns an empty success payload.
const MOCK_CURL = `#!/bin/bash
set -euo pipefail
printf '%s\\n' "$@" > "${'${ARGS_FILE}'}"
printf '{"status":"success","data":{"result":[]}}\\n'
`

async function withMockCurl() {
    const tempDir = await mkdtemp(join(tmpdir(), 'grafana-query-test-'))
    const argsFile = join(tempDir, 'curl-args.txt')
    const mockCurl = join(tempDir, 'mock-curl.sh')
    await writeFile(mockCurl, MOCK_CURL.replace('${ARGS_FILE}', argsFile))
    await chmod(mockCurl, 0o755)
    return { tempDir, argsFile, mockCurl }
}

// Hermetic env: never load a developer's real .env, and start with no creds.
function baseEnv(overrides = {}) {
    return {
        ...process.env,
        GRAFANA_QUERY_ENV_FILE: '/dev/null',
        GRAFANA_ENV: '',
        GRAFANA_DEFAULT_ENV: '',
        GRAFANA_BASE_URL: '',
        GRAFANA_TOKEN: '',
        GRAFANA_COOKIE: '',
        ...overrides,
    }
}

test('promql uses bearer-token auth and the Prometheus proxy path', async () => {
    const { argsFile, mockCurl } = await withMockCurl()
    await execFileAsync(
        promqlScript,
        ['--start', '1712775600', '--end', '1712775900', '--step', '15s', 'up{job="api"}'],
        {
            env: baseEnv({
                CURL_BIN: mockCurl,
                GRAFANA_BASE_URL: 'https://grafana.example.com',
                GRAFANA_TOKEN: 'tok_123',
            }),
        }
    )
    const args = await readFile(argsFile, 'utf8')
    assert.match(args, /Authorization: Bearer tok_123/)
    assert.doesNotMatch(args, /Cookie:/)
    assert.match(args, /api\/datasources\/proxy\/uid\/prometheus\/api\/v1\/query_range/)
    assert.match(args, /query=up\{job="api"\}/)
    assert.match(args, /start=1712775600/)
    assert.match(args, /step=15s/)
    assert.match(args, /https:\/\/grafana\.example\.com\//)
})

test('promql falls back to cookie auth when no token is set', async () => {
    const { argsFile, mockCurl } = await withMockCurl()
    await execFileAsync(promqlScript, ['up'], {
        env: baseEnv({
            CURL_BIN: mockCurl,
            GRAFANA_BASE_URL: 'https://grafana.example.com',
            GRAFANA_COOKIE: '_oauth2_proxy=abc',
        }),
    })
    const args = await readFile(argsFile, 'utf8')
    assert.match(args, /Cookie: _oauth2_proxy=abc/)
    assert.doesNotMatch(args, /Authorization:/)
})

test('logql uses the Loki proxy path', async () => {
    const { argsFile, mockCurl } = await withMockCurl()
    await execFileAsync(logqlScript, ['--since', '900', '--limit', '50', '{app="x"}'], {
        env: baseEnv({
            CURL_BIN: mockCurl,
            GRAFANA_BASE_URL: 'https://grafana.example.com',
            GRAFANA_TOKEN: 'tok_123',
        }),
    })
    const args = await readFile(argsFile, 'utf8')
    assert.match(args, /api\/datasources\/proxy\/uid\/loki\/loki\/api\/v1\/query_range/)
    assert.match(args, /limit=50/)
})

test('a named environment selects its own base URL and credentials', async () => {
    const { argsFile, mockCurl } = await withMockCurl()
    await execFileAsync(promqlScript, ['up'], {
        env: baseEnv({
            CURL_BIN: mockCurl,
            GRAFANA_ENV: 'staging',
            GRAFANA_PROD_BASE_URL: 'https://grafana.example.com',
            GRAFANA_PROD_TOKEN: 'prod_tok',
            GRAFANA_STAGING_BASE_URL: 'https://grafana.staging.example.com',
            GRAFANA_STAGING_COOKIE: '_oauth2_proxy=staging',
        }),
    })
    const args = await readFile(argsFile, 'utf8')
    assert.match(args, /https:\/\/grafana\.staging\.example\.com\//)
    assert.match(args, /Cookie: _oauth2_proxy=staging/)
    assert.doesNotMatch(args, /prod_tok/)
})

test('a clear error is raised when no base URL is configured', async () => {
    await assert.rejects(
        execFileAsync(promqlScript, ['up'], { env: baseEnv() }),
        error => {
            assert.equal(error.code, 1)
            assert.match(error.stderr, /No Grafana base URL configured/)
            return true
        }
    )
})

test('a clear error is raised when no credentials are configured', async () => {
    await assert.rejects(
        execFileAsync(promqlScript, ['up'], {
            env: baseEnv({ GRAFANA_BASE_URL: 'https://grafana.example.com' }),
        }),
        error => {
            assert.equal(error.code, 1)
            assert.match(error.stderr, /No Grafana credentials configured/)
            return true
        }
    )
})

test('incident list shows the example presets', async () => {
    const { stdout } = await execFileAsync(incidentScript, ['list'], {
        env: baseEnv({ GRAFANA_QUERY_PRESETS_DIR: join(scriptDir, 'presets', 'example') }),
    })
    assert.match(stdout, /kafka\/consumer-lag/)
    assert.match(stdout, /http\/error-rate/)
    assert.match(stdout, /queue\/depth-by-name/)
})

test('incident run dispatches a preset to the right datasource with its query', async () => {
    const { argsFile, mockCurl } = await withMockCurl()
    await execFileAsync(incidentScript, ['run', 'http/error-rate'], {
        env: baseEnv({
            CURL_BIN: mockCurl,
            GRAFANA_QUERY_PRESETS_DIR: join(scriptDir, 'presets', 'example'),
            GRAFANA_BASE_URL: 'https://grafana.example.com',
            GRAFANA_TOKEN: 'tok_123',
        }),
    })
    const args = await readFile(argsFile, 'utf8')
    assert.match(args, /api\/datasources\/proxy\/uid\/prometheus\/api\/v1\/query/)
    assert.match(args, /http_requests_total\{status=~"5\.\."\}/)
})

test('incident loads presets from a custom GRAFANA_QUERY_PRESETS_DIR', async () => {
    const tempDir = await mkdtemp(join(tmpdir(), 'grafana-presets-'))
    await writeFile(
        join(tempDir, 'custom.sh'),
        `define_preset "custom/my-preset" promql 'up' "a custom preset"\n`
    )
    const { stdout } = await execFileAsync(incidentScript, ['list'], {
        env: baseEnv({ GRAFANA_QUERY_PRESETS_DIR: tempDir }),
    })
    assert.match(stdout, /custom\/my-preset/)
    assert.doesNotMatch(stdout, /http\/error-rate/)
})

test('installed-plugin scenario: .env and presets resolve from the user config dir', async () => {
    // Simulate a managed plugin install: scripts in a bare directory with no
    // .env and no presets/local, config living in $XDG_CONFIG_HOME/grafana-tools.
    const { argsFile, mockCurl } = await withMockCurl()
    const pluginDir = await mkdtemp(join(tmpdir(), 'grafana-plugin-root-'))
    for (const f of ['common.sh', 'promql.sh', 'logql.sh', 'incident.sh']) {
        await copyFile(join(scriptDir, f), join(pluginDir, f))
        await chmod(join(pluginDir, f), 0o755)
    }

    const xdgDir = await mkdtemp(join(tmpdir(), 'grafana-xdg-'))
    const configDir = join(xdgDir, 'grafana-tools')
    await mkdir(join(configDir, 'presets'), { recursive: true })
    await writeFile(
        join(configDir, '.env'),
        'GRAFANA_BASE_URL=https://grafana.from-config.example.com\nGRAFANA_TOKEN=tok_from_config\n'
    )
    await writeFile(
        join(configDir, 'presets', 'team.sh'),
        `define_preset "team/up" promql 'up' "team preset from config dir"\n`
    )

    const env = baseEnv({
        CURL_BIN: mockCurl,
        XDG_CONFIG_HOME: xdgDir,
        GRAFANA_QUERY_ENV_FILE: '', // empty -> fall through the lookup chain
        GRAFANA_QUERY_PRESETS_DIR: '',
    })

    const { stdout } = await execFileAsync(join(pluginDir, 'incident.sh'), ['list'], { env })
    assert.match(stdout, /team\/up/)

    await execFileAsync(join(pluginDir, 'incident.sh'), ['run', 'team/up'], { env })
    const args = await readFile(argsFile, 'utf8')
    assert.match(args, /https:\/\/grafana\.from-config\.example\.com\//)
    assert.match(args, /Authorization: Bearer tok_from_config/)
})

test('report prints usage text', async () => {
    const { stdout } = await execFileAsync(reportScript, ['--help'], { env: baseEnv() })
    assert.match(stdout, /Usage: report\.sh --start-date YYYY-MM-DD/)
    assert.match(stdout, /report definition/i)
})

test('report renders the example definition end-to-end and writes artifacts', async () => {
    const { mockCurl } = await withMockCurl()
    const outDir = await mkdtemp(join(tmpdir(), 'grafana-report-out-'))
    await execFileAsync(
        reportScript,
        ['--start-date', '2026-01-01', '--days', '2', '--out-dir', outDir, '--prefix', 'smoke'],
        {
            env: baseEnv({
                CURL_BIN: mockCurl,
                GRAFANA_QUERY_REPORTS_DIR: join(scriptDir, 'reports', 'example'),
                GRAFANA_BASE_URL: 'https://grafana.example.com',
                GRAFANA_TOKEN: 'tok_123',
            }),
        }
    )
    const files = await readdir(outDir)
    assert.ok(files.includes('smoke.md'), 'markdown report written')
    assert.ok(files.includes('smoke.json'), 'json artifact written')
    assert.ok(files.includes('smoke-kafka-topic-volume.csv'), 'per-section csv written')
    const md = await readFile(join(outDir, 'smoke.md'), 'utf8')
    assert.match(md, /# Service Overview Report/)
    assert.match(md, /## Request Volume/)
    assert.match(md, /## Top Error Services/)
})
