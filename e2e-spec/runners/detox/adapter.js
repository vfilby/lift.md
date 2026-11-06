/**
 * Detox Adapter - Maps YAML actions to Detox API calls.
 *
 * Each action type has a corresponding handler that translates the
 * declarative YAML action into imperative Detox commands.
 */

const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');

const FIXTURES_DIR = path.resolve(__dirname, '../../fixtures');

/**
 * Resolve an element matcher from action params.
 * Supports: target (by.id), text (by.text), label (by.label).
 */
function resolveElement(action) {
  if (action.target) {
    return element(by.id(action.target));
  }
  if (action.text) {
    return element(by.text(action.text));
  }
  if (action.label) {
    return element(by.label(action.label));
  }
  throw new Error(`No element selector in action: ${JSON.stringify(action)}`);
}

/**
 * Resolve element at a specific index (for multiple matches).
 */
function resolveElementAtIndex(action) {
  if (action.target) {
    return element(by.id(action.target)).atIndex(action.index || 0);
  }
  if (action.text) {
    return element(by.text(action.text)).atIndex(action.index || 0);
  }
  throw new Error(`No element selector in tapIndex action: ${JSON.stringify(action)}`);
}

/**
 * Read a fixture file and return its content.
 */
function readFixture(fixtureName) {
  const fixturePath = path.join(FIXTURES_DIR, fixtureName);
  if (!fs.existsSync(fixturePath)) {
    throw new Error(`Fixture not found: ${fixturePath}`);
  }
  return fs.readFileSync(fixturePath, 'utf-8');
}

/**
 * Resolve the value for a replaceText action.
 * If `fixture` is specified, reads the fixture file content.
 * Otherwise uses `value` directly.
 */
function resolveTextValue(action) {
  if (action.fixture) {
    return readFixture(action.fixture);
  }
  if (action.value !== undefined) {
    return action.value;
  }
  throw new Error(`replaceText action needs either 'value' or 'fixture': ${JSON.stringify(action)}`);
}

/**
 * Action handlers - each maps a YAML action type to Detox calls.
 */
const actionHandlers = {
  async tap(action) {
    await resolveElement(action).tap();
  },

  async longPress(action) {
    await resolveElement(action).longPress();
  },

  async tapText(action) {
    await element(by.text(action.text)).tap();
  },

  async tapIndex(action) {
    await resolveElementAtIndex(action).tap();
  },

  async replaceText(action) {
    const value = resolveTextValue(action);
    await element(by.id(action.target)).replaceText(value);
  },

  async typeText(action) {
    await element(by.id(action.target)).typeText(action.value);
  },

  async waitFor(action) {
    const timeout = action.timeout || 5000;
    if (action.target) {
      await waitFor(element(by.id(action.target)))
        .toBeVisible()
        .withTimeout(timeout);
    } else if (action.text) {
      await waitFor(element(by.text(action.text)))
        .toBeVisible()
        .withTimeout(timeout);
    } else {
      throw new Error(`waitFor needs target or text: ${JSON.stringify(action)}`);
    }
  },

  async waitForNot(action) {
    const timeout = action.timeout || 5000;
    if (action.target) {
      await waitFor(element(by.id(action.target)))
        .not.toBeVisible()
        .withTimeout(timeout);
    } else if (action.text) {
      await waitFor(element(by.text(action.text)))
        .not.toBeVisible()
        .withTimeout(timeout);
    } else {
      throw new Error(`waitForNot needs target or text: ${JSON.stringify(action)}`);
    }
  },

  async waitForText(action) {
    const timeout = action.timeout || 5000;
    await waitFor(element(by.text(action.text)))
      .toBeVisible()
      .withTimeout(timeout);
  },

  async expect(action) {
    const el = action.target
      ? element(by.id(action.target))
      : element(by.text(action.text));

    switch (action.assertion) {
      case 'toBeVisible':
        await expect(el).toBeVisible();
        break;
      case 'toBeOnScreen':
        // Detox visibility never scrolls, so this is on-screen by definition.
        await waitFor(el).toBeVisible().withTimeout(action.timeout || 5000);
        break;
      case 'toHaveText':
        await expect(el).toHaveText(action.value);
        break;
      case 'toExist':
        await expect(el).toExist();
        break;
      case 'notToBeVisible':
        await expect(el).not.toBeVisible();
        break;
      case 'notToExist':
        await expect(el).not.toExist();
        break;
      default:
        throw new Error(`Unknown assertion: ${action.assertion}`);
    }
  },

  async scroll(action) {
    const amount = action.amount || 300;
    await element(by.id(action.target)).scroll(amount, action.direction);
  },

  async launchApp(action) {
    const params = {};
    if (action.newInstance) params.newInstance = true;
    if (action.permissions) params.permissions = action.permissions;
    if (action.launchArgs) params.launchArgs = action.launchArgs;
    await device.launchApp(params);
  },

  async openURL(action) {
    let url = action.url;
    // Replace {sharedFilePath} placeholder if present
    if (url.includes('{sharedFilePath}') && actionHandlers._sharedFilePath) {
      url = url.replace('{sharedFilePath}', actionHandlers._sharedFilePath);
    }
    await device.openURL({ url });
  },

  async dismissAlert(action) {
    await element(by.text(action.button)).tap();
  },

  async delay(action) {
    await new Promise(resolve => setTimeout(resolve, action.ms));
  },

  async tryCatch(action) {
    try {
      for (const step of action.try) {
        await executeAction(step);
      }
    } catch (error) {
      const catchSteps = action.catch || [];
      for (const step of catchSteps) {
        await executeAction(step);
      }
    }
  },

  async runFixture(action) {
    const content = readFixture(action.fixture);
    // Navigate to home, open import, paste content, confirm
    await element(by.id('tab-home')).tap();
    await new Promise(resolve => setTimeout(resolve, 500));
    await waitFor(element(by.id('button-import-workout')))
      .toBeVisible()
      .withTimeout(5000);
    await element(by.id('button-import-workout')).tap();
    await waitFor(element(by.id('input-markdown')))
      .toBeVisible()
      .withTimeout(10000);
    await element(by.id('input-markdown')).replaceText(content);
    await element(by.id('button-import')).tap();
    await waitFor(element(by.text('OK')))
      .toBeVisible()
      .withTimeout(10000);
    await element(by.text('OK')).tap();
    await waitFor(element(by.text(action.expectedName)))
      .toBeVisible()
      .withTimeout(10000);
  },

  async execScript(action) {
    if (action.script === 'writeSharedFile') {
      const appDataDir = execSync(
        'xcrun simctl get_app_container booted com.eff3.liftmark data'
      ).toString().trim();

      const inboxDir = path.join(appDataDir, 'Documents', 'Inbox');
      fs.mkdirSync(inboxDir, { recursive: true });

      let content;
      if (action.args.fixture) {
        content = readFixture(action.args.fixture);
      } else {
        content = action.args.content;
      }

      const filename = action.args.filename || 'test.md';
      const testFile = path.join(inboxDir, filename);
      fs.writeFileSync(testFile, content);

      // Store path for openURL placeholder resolution
      const urlPath = testFile.replace(/^\//, '');
      actionHandlers._sharedFilePath = urlPath;
    } else {
      throw new Error(`Unknown execScript: ${action.script}`);
    }
  },

  // Internal state for cross-action communication
  _sharedFilePath: null,
};

/**
 * Execute a single YAML action by dispatching to the appropriate handler.
 */
async function executeAction(action) {
  const handler = actionHandlers[action.action];
  if (!handler) {
    throw new Error(`Unknown action type: ${action.action}`);
  }
  await handler(action);
}

module.exports = { executeAction, readFixture };
