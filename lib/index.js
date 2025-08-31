/**
 * Multi-Model Review Pipeline
 * Main library entry point
 */

import ConfigLoader from './config-loader.js';
import CommandBuilder from './command-builder.js';
import ProviderExecutor from './execute-provider.js';
import CriteriaBuilder from './criteria-builder.js';
import { spawn } from 'node:child_process';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { mkdir } from 'node:fs/promises';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);
const packageDir = dirname(__dirname);

/**
 * Main ReviewPipeline class for programmatic API
 */
export class ReviewPipeline {
  constructor(options = {}) {
    this.options = {
      projectRoot: process.cwd(),
      configFile: '.reviewrc.json',
      providers: ['claude', 'codex', 'gemini'],
      parallel: true,
      timeout: 600,
      verbose: false,
      ...options
    };
    
    this.configLoader = new ConfigLoader({
      projectConfigPath: join(this.options.projectRoot, this.options.configFile),
      verbose: this.options.verbose
    });
    
    this.results = [];
    this.errors = [];
  }

  /**
   * Run the complete review pipeline
   */
  async run() {
    try {
      // Load configuration
      await this.configLoader.load();
      const config = this.configLoader.config;
      
      // Create workspace directories
      const workspaceDir = join(packageDir, 'workspace');
      await mkdir(join(workspaceDir, 'context'), { recursive: true });
      await mkdir(join(workspaceDir, 'reports'), { recursive: true });
      
      // Build context
      await this.buildContext();
      
      // Run tests if configured
      if (config.testing?.enabled && config.testing?.command) {
        await this.runTests(config.testing.command, config.testing.timeout_seconds);
      }
      
      // Run provider reviews
      const providers = this.options.providers;
      if (this.options.parallel && config.execution?.parallel !== false) {
        await this.runProvidersParallel(providers);
      } else {
        await this.runProvidersSequential(providers);
      }
      
      // Aggregate results
      await this.aggregateResults();
      
      return {
        success: this.errors.length === 0,
        results: this.results,
        errors: this.errors,
        summary: await this.getSummary()
      };
    } catch (error) {
      this.errors.push(error.message);
      throw error;
    }
  }

  /**
   * Build review context (diff, files, metadata)
   */
  async buildContext() {
    // This would be implemented to gather git diff, changed files, etc.
    // For now, delegates to the shell script
    return this.runScript('build-context.sh');
  }

  /**
   * Run tests
   */
  async runTests(command, timeout = 300) {
    return new Promise((resolve, reject) => {
      const child = spawn('sh', ['-c', command], {
        cwd: this.options.projectRoot,
        timeout: timeout * 1000,
        env: {
          ...process.env,
          PROJECT_ROOT: this.options.projectRoot
        }
      });
      
      let output = '';
      child.stdout.on('data', (data) => {
        output += data.toString();
      });
      
      child.stderr.on('data', (data) => {
        output += data.toString();
      });
      
      child.on('exit', (code) => {
        if (code !== 0) {
          this.errors.push(`Tests failed with exit code ${code}`);
        }
        resolve({ code, output });
      });
      
      child.on('error', reject);
    });
  }

  /**
   * Run providers in parallel
   */
  async runProvidersParallel(providers) {
    const promises = providers.map(provider => this.runProvider(provider));
    const results = await Promise.allSettled(promises);
    
    results.forEach((result, index) => {
      if (result.status === 'fulfilled') {
        this.results.push(result.value);
      } else {
        this.errors.push(`Provider ${providers[index]} failed: ${result.reason}`);
      }
    });
  }

  /**
   * Run providers sequentially
   */
  async runProvidersSequential(providers) {
    for (const provider of providers) {
      try {
        const result = await this.runProvider(provider);
        this.results.push(result);
      } catch (error) {
        this.errors.push(`Provider ${provider} failed: ${error.message}`);
      }
    }
  }

  /**
   * Run a single provider
   */
  async runProvider(provider) {
    const executor = new ProviderExecutor();
    return executor.execute(provider, {
      projectRoot: this.options.projectRoot,
      timeout: this.options.timeout
    });
  }

  /**
   * Aggregate results from all providers
   */
  async aggregateResults() {
    // This would aggregate the JSON results from all providers
    // For now, delegates to the aggregation script
    return this.runScript('aggregate-reviews.mjs');
  }

  /**
   * Get summary of results
   */
  async getSummary() {
    // Read and return the generated summary
    const summaryPath = join(packageDir, 'workspace', 'summary.md');
    try {
      const { readFile } = await import('node:fs/promises');
      return await readFile(summaryPath, 'utf8');
    } catch {
      return 'No summary available';
    }
  }

  /**
   * Helper to run a script
   */
  runScript(scriptName) {
    return new Promise((resolve, reject) => {
      const scriptPath = join(packageDir, 'scripts', scriptName);
      const child = spawn('bash', [scriptPath], {
        cwd: this.options.projectRoot,
        env: {
          ...process.env,
          PROJECT_ROOT: this.options.projectRoot,
          PACKAGE_DIR: packageDir
        }
      });
      
      child.on('exit', (code) => {
        if (code === 0) {
          resolve();
        } else {
          reject(new Error(`Script ${scriptName} exited with code ${code}`));
        }
      });
      
      child.on('error', reject);
    });
  }
}

// Export all components
export { ConfigLoader, CommandBuilder, ProviderExecutor, CriteriaBuilder };
export default ReviewPipeline;