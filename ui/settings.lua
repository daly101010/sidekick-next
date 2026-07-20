-- Compatibility entry point. The modular settings implementation is
-- authoritative; retaining only this forwarding shim prevents old callers
-- from loading a second, divergent settings UI.
return require('sidekick-next.ui.settings.init')
