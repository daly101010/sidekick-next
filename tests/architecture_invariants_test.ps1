$ErrorActionPreference = 'Stop'

$failures = [System.Collections.Generic.List[string]]::new()
$checked = 0

function Require-Text {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Description
    )
    $script:checked++
    $content = Get-Content -LiteralPath $Path -Raw
    if (-not $content.Contains($Text)) {
        $script:failures.Add("${Path}: missing ${Description}")
    }
}

function Reject-Text {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Text,
        [Parameter(Mandatory)][string]$Description
    )
    $script:checked++
    $content = Get-Content -LiteralPath $Path -Raw
    if ($content.Contains($Text)) {
        $script:failures.Add("${Path}: contains ${Description}")
    }
}

function Require-Regex {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Description
    )
    $script:checked++
    $content = Get-Content -LiteralPath $Path -Raw
    if (-not [regex]::IsMatch($content, $Pattern)) {
        $script:failures.Add("${Path}: missing ${Description}")
    }
}

Require-Text 'sk_module_base.lua' 'function self:cancelUnifiedAction' 'central unified-executor cancellation'
Require-Text 'sk_module_base.lua' 'ActionExecutor.consumeResult()' 'executor terminal-result drain'
Require-Text 'sk_module_base.lua' "boundaryReason or 'boundary_rejected')" 'mutation-boundary executor cleanup'
Require-Text 'sk_module_base.lua' 'recovery_required:executor_withdraw' 'withdraw-path executor fencing'
Require-Text 'sk_lib.lua' 'function M.actorSenderMatches' 'fully-qualified Actor sender authentication'
Reject-Text 'sk_module_base.lua' "tostring(sender.script or '') ~= tostring(lib.Scripts.COORDINATOR or '')" 'nonexistent Actor sender.script validation'
Require-Text 'ui/coordinator_debug.lua' 'lib.actorSenderMatches(sender,' 'UI coordinator mailbox authentication'

Require-Text 'healing/init.lua' 'if opts.readOnly == nil then opts.readOnly = true end' 'read-only healing sensor default'
Reject-Text 'sk_healing.lua' 'Healing.tickSensors()' 'unqualified healing sensor call'

Require-Text 'sk_chase.lua' 'Movement.inspectOrphanRecovery()' 'read-only chase orphan inspection'
Require-Text 'sk_chase.lua' 'self:markDirtyEffects(true, true)' 'fenced chase recovery request'
Require-Text 'sk_module_base.lua' 'lastRecoveryReportAtMs' 'recovery completion report deduplication'
Require-Text 'sk_coordinator.lua' 'worker_recovery_heartbeat_fenced' 'stale dirty-heartbeat recovery fence'

Require-Text 'sk_coordinator.lua' 'actorQueueOverflows' 'coordinator Actor queue overflow telemetry'
Require-Text 'sk_coordinator.lua' 'workerProtocolRejects' 'worker protocol rejection telemetry'
Require-Text 'sk_coordinator.lua' 'supervisorProtocolRejects' 'supervisor protocol rejection telemetry'
Require-Text 'utils/supervisor.lua' 'version = lib.LEASE_PROTOCOL_VERSION' 'versioned supervisor packets'
Require-Text 'utils/supervisor.lua' 'pendingMessageOverflows' 'supervisor Actor queue overflow telemetry'
Reject-Text 'utils/supervisor.lua' 'table.remove(pendingMessages, 1)' 'linear-time supervisor queue eviction'

Require-Text 'utils/spellset_memorize.lua' 'ActorsCoordinator.ENVELOPE_VERSION' 'shared peer-envelope version'
Reject-Text 'utils/spellset_memorize.lua' 'tonumber(envelope.version) == 2' 'hard-coded peer-envelope version'
Require-Text 'utils/offensive_target.lua' 'tankUpdatedAt > 0' 'positive authoritative-target timestamp sentinel'
Require-Text 'utils/runtime_cache.lua' 'mq.TLO.Me.XTarget(1)' 'configured Auto-Hater slot-1 wake-up sentinel'
Reject-Text 'utils/runtime_cache.lua' 'mq.TLO.Me.XTargetSlots()' 'all-slot hostile wake-up scan'

Reject-Text 'sk_dps.lua' 'local function addActorTargetCandidates' 'shadow Actor target selector'
Reject-Text 'sk_dps.lua' 'local function addXTargetCandidates' 'shadow XTarget selector'
Reject-Text 'sk_dps.lua' '_lastValidTarget' 'unused legacy target cache'

Reject-Text 'docs/USER_GUIDE.md' 'SpellRotationEnabled' 'removed SpellRotationEnabled setting'
Require-Text 'SideKick.lua' "Core.set('AutomationPaused', false, { source = 'startup_auto_resume' })" 'startup auto-resume'
Reject-Text 'automation/chase.lua' "settings.AutomationPaused == true" 'stale process-local Chase pause gate'
Require-Text 'automation/chase.lua' 'if settings.CasterStandoffEnabled == true and M.hasStandoffDemand() then' 'standoff-demand-scoped Chase combat yield'
Require-Text 'automation/chase.lua' 'local leash = math.max(150, chaseDistance * 4)' 'Chase combat leash exception'
Require-Text 'automation/chase.lua' 'M.combatBlockReason(settings, spawn)' 'validated Chase target combat gate'
Reject-Text 'docs/USER_GUIDE.md' 'automation/tank.lua' 'nonexistent tank helper path'
Require-Text 'docs/INTEGRATION_GUIDE.md' 'mandatory dirty-effect recovery' 'mandatory recovery-preemption semantics'

Require-Text 'sk_lib.lua' 'M.ConsolidatedWorkerRegistry' 'ten-worker consolidated profile'
Require-Text 'sk_lib.lua' "module = 'support'" 'Support domain worker'
Require-Text 'sk_lib.lua' "module = 'combat'" 'Combat domain worker'
Require-Text 'sk_lib.lua' "module = 'maintenance'" 'Maintenance domain worker'
Reject-Text 'sk_lib.lua' "module = 'fidget'," 'supervised Fidget worker'
Require-Text 'utils/domain_orchestrator.lua' 'copy.component = componentName' 'domain action attribution'
Require-Text 'utils/domain_orchestrator.lua' 'domainRecoveryComponent' 'component recovery routing'
Require-Text 'utils/domain_orchestrator.lua' 'ActionExecutor.USE_DEFAULT_DISPATCH' 'domain native-dispatch fallback'
Require-Text 'sk_module_base.lua' "ActionCounters.bump(string.format('failed:%s:%s'," 'component/reason failure counters'
Require-Text 'SideKick.lua' "sendWorkerCommand('items', 'activate'" 'standard manual ability command'
Require-Text 'sk_items.lua' "registerWorkerCommand('items'" 'standard manual ability worker receiver'
Require-Text 'sk_items.lua' 'ActionExecutor.USE_DEFAULT_DISPATCH' 'manual action native executor routing'
Require-Text 'sk_items.lua' "local CURSOR_HOLD_MS = 5000" 'five-second cursor grace'
Require-Text 'sk_items.lua' "local CURSOR_SCAN_MS = 250" 'throttled cursor TLO sensor'
Require-Text 'sk_items.lua' "mq.cmd('/autoinventory')" 'lease-owned cursor auto-inventory'
Require-Text 'sk_items.lua' "'cursor_item_changed'" 'cursor mutation boundary identity check'
Reject-Text 'SideKick.lua' 'Abilities.activate(' 'direct UI ability activation'
Reject-Text 'ui/item_bar_animated.lua' 'Items.useItem(entry.itemName' 'direct ImGui item activation'
Require-Text 'ui/remote_abilities.lua' "ActorsCoordinator.sendWorkerCommand('items'" 'leased remote ability routing'
Reject-Text 'ui/remote_abilities.lua' "mq.cmdf('/dex" 'direct remote ability activation'
Reject-Text 'sk_dps.lua' 'directTestCast' 'direct DPS debug cast bypass'
Require-Text 'utils/abilities.lua' "'direct_activation_disabled'" 'fail-closed legacy ability activation'
Require-Text 'ui/spell_set_ooc_tab.lua' 'local _, clicked = imgui.Selectable(label, currentIdx == i)' 'OOC buff target combo click result'
Require-Text 'ui/spell_set_ooc_tab.lua' 'buffConfig.buffTarget = nil' 'removable OOC buff target override'
Require-Text 'sk_buffs.lua' 'local liveRecipientId = action.isGroup' 'live pre-cast buff recipient revalidation'
Require-Text 'sk_buffs.lua' 'spell.StacksTarget()' 'live target stacking guard'
Require-Text 'sk_buffs.lua' "'already_buffed'" 'duplicate buff cast suppression'
Require-Text 'sk_buffs.lua' "or cls == 'PAL' or cls == 'SHD' or cls == 'RNG' or cls == 'BST'" 'hybrid caster buff-target classification'
Require-Text 'utils/spellset_manager.lua' "or cls == 'PAL' or cls == 'SHD' or cls == 'RNG' or cls == 'BST'" 'legacy hybrid caster buff-target classification'
Require-Text 'sk_support.lua' "components = { 'healing', 'cures', 'resurrection' }" 'Support component order'
Require-Text 'sk_support.lua' 'cache = true' 'Support runtime cache ticking'
Require-Text 'sk_combat.lua' "components = { 'cc', 'feign', 'debuff', 'assist', 'disciplines', 'dps' }" 'Combat component order'
Require-Text 'sk_combat.lua' 'shouldSuppressActive' 'managed-feign exclusive safety hold'
Require-Text 'sk_maintenance.lua' "components = { 'resources', 'buffs' }" 'Maintenance component order'
Require-Text 'utils/runtime_cache.lua' 'cache_not_ready' 'runtime cache readiness contract'
Require-Text 'utils/runtime_cache.lua' 'function M.hasAutoHaterActivity' 'Auto-Hater activity sentinel'
Require-Text 'utils/runtime_cache.lua' 'function M.setHeavyScanEnabled' 'process-local heavy scan gate'
Require-Text 'utils/lease_scheduler.lua' 'function M:heartbeatNeedsRecovery' 'active-effect versus orphan-recovery distinction'
Require-Text 'sk_module_base.lua' 'function self:markDirtyEffects(value, recoveryRequired)' 'explicit recovery-required effect reporting'
Require-Text 'utils/actors_coordinator.lua' 'function M.getPrimaryKillAuthorization' 'positive Tank kill authorization'
Require-Text 'utils/actors_coordinator.lua' 'local function selectedAssistAuthority()' 'single selected assist authority'
Require-Text 'utils/actors_coordinator.lua' "source = 'raid_assist_1'" 'default raid-assist authority'
Require-Text 'utils/actors_coordinator.lua' 'local spawn = member.Spawn' 'raidmember-to-spawn resolution'
Require-Text 'utils/actors_coordinator.lua' 'or authorityChanged' 'stale prior-authority target invalidation'
Require-Text 'sk_combat.lua' 'domainKillAuthorized' 'Combat offensive authorization gate'
Require-Text 'sk_combat.lua' "'assist_source:' .. assistMode" 'non-Tank main-assist target fallback'
Require-Text 'sk_combat.lua' 'local combatActivity = hostileActivity or authorized' 'Tank-primary Combat admission'
Require-Text 'sk_combat.lua' 'host.domainCacheEnabled = combatActivity' 'Combat cache admission gate'
Require-Text 'sk_combat.lua' "'kill_gate:'" 'Combat idle gate diagnostics'
Require-Text 'ui/coordinator_debug.lua' 'Authorized Kill Target ID' 'explicit kill-authorization diagnostics'
Require-Text 'ui/coordinator_debug.lua' 'Selected Assist Authority' 'selected assist authority diagnostics'
Require-Text 'SideKick.lua' "'/sk_next_set_raid_assist'" 'raid-wide persisted assist command'
Require-Text 'SideKick.lua' 'Core.load({ primaryWriter = true })' 'explicit primary settings writer declaration'
Require-Text 'utils/core.lua' 'return _primaryWriter == true' 'stack-independent settings writer ownership'
Require-Text 'registry.lua' 'RaidAssistOverrideActive' 'raid-scoped assist override marker'
Require-Text 'SideKick.lua' "AssistMode = 'group'" 'post-raid Group Main Assist restoration'
Require-Text 'SideKick.lua' "source = 'raid_assist_override_expired'" 'post-raid assist reset persistence'
Require-Text 'automation/chase.lua' 'spawn = member and member.Spawn or nil' 'raidmember chase spawn resolution'
Require-Text 'ui/coordinator_debug.lua' "'Pending: ' .. priorityName" 'pending priority distinguished from active lease'
Require-Text 'sk_disciplines.lua' "targetRole == 'kill'" 'Disciplines exact primary-target binding'
Require-Text 'sk_dps.lua' 'kill_authorization_changed' 'DPS mutation-boundary authorization'
Require-Text 'sk_debuff.lua' 'kill_authorization_changed' 'Debuff mutation-boundary authorization'
Require-Text 'sk_cc.lua' 'kill_authorization_changed' 'Charm-pet attack authorization boundary'
Require-Text 'sk_tank.lua' "reason = 'no_auto_hater'" 'Tank Auto-Hater action gate'
Require-Text 'registry.lua' 'TankFleeMinRecedeRate' 'adjustable runner recede rate'
Require-Text 'sk_tank.lua' 'NamedDetector.isNamed(target, _settings)' 'named runner handoff exclusion'
Require-Text 'sk_tank.lua' 'pickWorkingTarget(false)' 'unmezzed runner-handoff priority'
Require-Text 'sk_tank.lua' 'pickWorkingTarget(true)' 'mezzed runner-handoff fallback'
Require-Text 'sk_tank.lua' "tankAction = 'runner_handoff'" 'long-lived runner-handoff action'
Require-Text 'sk_tank.lua' "job.tank.phase = 'runner_handoff_hold'" 'runner-handoff lease hold phase'
Require-Text 'sk_tank.lua' 'mq.TLO.Stick.StickTarget()' 'exact Stick-target ownership fence'
Require-Text 'sk_tank.lua' "'stopping_runner_handoff_stick'" 'runner-handoff finalizer drain'
Reject-Text 'sk_tank.lua' "return nil, lib.Priority.TANK_ENGAGE, 'runner_handoff_holding'" 'short runner-handoff idle path'
Require-Text 'ui/settings/tab_automation.lua' "'Hand Off Fleeing Mobs'" 'runner handoff UI toggle'
Require-Text 'automation/cc.lua' "M.broadcastCharmState(true)" 'persistent charm protection publication'
Require-Text 'automation/cc.lua' 'active = (tonumber(M.charm.petId) or 0) > 0' 'active-versus-broken charm publication'
Require-Text 'utils/actors_coordinator.lua' 'function M.isActiveCharmPet' 'active charm-pet state query'
Require-Text 'sk_tank.lua' 'and not Actors.isActiveCharmPet(action.targetId)' 'broken-only charm-pet Taunt allowance'
Require-Text 'sk_tank.lua' 'stopOffensiveEngagement(currentTargetId, true)' 'immediate active-charm Tank cleanup'
Require-Text 'sk_tank.lua' 'if enabled then' 'new charm-protection leases gated to enabled Tank'
Require-Text 'sk_tank.lua' 'A disabled/non-tank Tank worker did not arm that target' 'non-tank charm-target ownership fence'
Require-Text 'sk_resurrection.lua' 'local function findRezTargets' 'complete resurrection candidate enumeration'
Require-Text 'sk_resurrection.lua' 'selectRangeEligibleTarget(candidates, resource, inCombat)' 'range-aware resurrection candidate selection'
Require-Text 'sk_resurrection.lua' 'candidateCount = Runtime.candidateCount' 'resurrection candidate-count telemetry'
Reject-Text 'sk_resurrection.lua' 'findRezTarget(inCombat)' 'single-candidate resurrection selection'
Require-Text 'sk_module_base.lua' "self:traceAction('requested'" 'worker action trace'
Require-Text 'sk_module_base.lua' "'Lease granted: component=%s action=%s%s target=%s queued=%dms'" 'in-game lease grant logging'
Require-Text 'sk_module_base.lua' "'Lease released: component=%s action=%s%s target=%s reason=%s held=%dms'" 'in-game lease release logging'
Require-Text 'sk_tank.lua' "local ENGAGE_VERIFY_MS = 1500" 'bounded tank engage confirmation'
Require-Text 'sk_tank.lua' "Counters.bump('engage_confirmed')" 'verified tank engagement'
Require-Text 'sk_tank.lua' 'or not _killAuthorized or _forceEngage' 'tank cannot hold an unverified primary'
Require-Text 'sk_tank.lua' "'engage_approach_timeout', 'failed'" 'failed tank approach cannot authorize offense'
Require-Text 'utils/actors_coordinator.lua' "if state.killAuthorized ~= true then" 'explicit tank kill authorization gate'
Require-Text 'utils/actors_coordinator.lua' "'primary_not_engaged'" 'unverified tank-primary diagnostic'
Require-Text 'sk_coordinator.lua' 'dropReasons' 'coordinator counted drop reasons'
Require-Text 'utils/actors_coordinator.lua' 'byReason' 'peer transport counted drop reasons'
Require-Text 'utils/actors_coordinator.lua' 'previous.topics[id]' 'transport ordering scoped by message topic'
Reject-Text 'utils/actors_coordinator.lua' 'sequence <= (previous.sequence or 0)' 'endpoint-wide cross-topic sequence rejection'
Require-Text 'utils/actors_coordinator.lua' 'local TOPIC_CONTRACTS = {' 'declared Actor topic routing'
Require-Text 'utils/actors_coordinator.lua' "['pull:incoming'] = { scope = 'fleet' }" 'cross-script pull-state contract'
Require-Text 'utils/actors_coordinator.lua' "['mobhp:update'] = { scope = 'fleet' }" 'cross-script mob-HP contract'
Require-Text 'utils/actors_coordinator.lua' "['assist:me'] = { scope = 'fleet' }" 'cross-script assist-command contract'
Require-Text 'utils/actors_coordinator.lua' "['buff:need'] = { scope = 'fleet' }" 'UI-to-Buff request contract'
Require-Text 'utils/actors_coordinator.lua' "return false, 'unregistered_publish_topic:'" 'unknown Actor topics fail closed'
Reject-Text 'utils/actors_coordinator.lua' 'function M.broadcast(' 'public same-script broadcast footgun'
Reject-Text 'utils/actors_coordinator.lua' 'function M.broadcastFleet(' 'public fleet broadcast footgun'
Reject-Text 'automation/cc.lua' 'Actors.broadcast' 'legacy CC broadcast capability guard'
Reject-Text 'automation/buff.lua' 'Actors.broadcast' 'legacy Buff broadcast capability guard'
Reject-Text 'automation/cures.lua' 'Actors.broadcast' 'legacy Cure broadcast capability guard'
Reject-Text 'automation/debuff.lua' 'Actors.broadcast' 'legacy Debuff broadcast capability guard'
Reject-Text 'healing/init.lua' 'ActorsCoordinator.broadcast and' 'legacy Healing broadcast capability guard'
Require-Text 'utils/actors_coordinator.lua' 'function M.registerTelemetryCallback' 'standard telemetry receive envelope'
Require-Text 'utils/actors_coordinator.lua' 'function M.sendTelemetryToScript' 'standard telemetry send envelope'
Require-Text 'utils/actors_coordinator.lua' 'function M.registerWorkerCommand' 'standard worker command receiver'
Require-Text 'utils/actors_coordinator.lua' 'function M.sendWorkerCommand' 'worker-registry command routing'
Require-Text 'utils/actors_coordinator.lua' "recordTransportDrop('worker_command_version')" 'counted worker command version rejection'
Require-Text 'utils/actors_coordinator.lua' "recordTransportDrop('telemetry_unhandled_stream')" 'counted telemetry routing rejection'
Require-Text 'utils/actors_coordinator.lua' 'function M.getOutboundMetrics' 'Actor publication/send accounting'
Require-Text 'sk_module_base.lua' 'peerOpts.peerVitals = buildPeerHeartbeat(self.name)' 'Support-only vitals overlay'
Reject-Text 'sk_module_base.lua' 'status = buildPeerHeartbeat(self.name)' 'all-worker duplicate presence publication'
Require-Text 'SideKick.lua' 'peerCapabilities = status' 'UI capability overlay'
Require-Text 'utils/actors_coordinator.lua' 'local function buildCapabilityOverlay' 'presence fields removed from capability overlay'
Require-Text 'automation/cc.lua' 'Actors.getTeamSnapshot()' 'Actor Team target authority'
Require-Text 'utils/actors_coordinator.lua' '_teamPresenceHistory' 'retained Actor Team liveness source'
Reject-Text 'utils/actors_coordinator.lua' 'peer = _remoteCharacters[peerKey(wantedServer, wantedName)]' 'legacy overlay as claim-liveness authority'
Require-Text 'sk_coordinator.lua' 'actorOutbound = buildActorTransportSummary(nowMs)' 'fleet Actor send aggregation'
Require-Text 'utils/actors_coordinator.lua' 'local assignedTankPrimary =' 'EQ-assigned Tank primary transport exception'
Require-Text 'utils/actors_coordinator.lua' 'and not assignedTankPrimary' 'Actor-Team gate preserves assigned Tank primary'
Require-Text 'utils/actors_coordinator.lua' 'isEqAssignedTargetLeader(senderName, content and content.tankId)' 'topic admission reuses EQ assignment identity'
Require-Text 'utils/actors_coordinator.lua' 'selected.id == claimedId' 'numeric EQ assignment validation'
Require-Text 'utils/actors_coordinator.lua' 'return claimedId > 0 and selected.id == claimedId' 'EQ assist ID bound to Tank claim'
Require-Text 'utils/actors_coordinator.lua' 'Explicit by-name authority is bound to the authenticated Actor' 'configured assist bound to transport identity'
Require-Text 'utils/actors_coordinator.lua' 'recordPrimaryTargetDiag' 'bounded primary-target admission diagnostics'
Require-Text 'utils/actors_coordinator.lua' "senderIsWorker(sender, 'tank')" 'canonical parsed Tank worker route'
Require-Text 'utils/actors_coordinator.lua' "'target_primary_unauthorized_leader'" 'counted primary authority rejection'
Require-Text 'utils/actors_coordinator.lua' "'target_primary_zone_or_instance_mismatch'" 'counted primary zone rejection'
Require-Text 'ui/coordinator_debug.lua' "'Primary Target Transport##primarytransport'" 'primary transport diagnostic UI'
Require-Text 'sk_tank.lua' "'primaryActor stage=%s reason=%s" 'Tank primary send diagnostics'
Require-Text 'sk_combat.lua' "mq.bind('/sk_combat'" 'Combat-local primary receive diagnostics'
Require-Text 'sk_combat.lua' "'executor phase=%s reason=%s" 'Combat executor lifecycle diagnostics'
Require-Text 'sk_combat.lua' "'spellEngine state=%s spell=%s" 'Combat spell-engine diagnostics'
Require-Text 'sk_combat.lua' "and 'cc_after_cast' or 'debuff_after_cast'" 'CC and Debuff defer to an in-flight cast'
Require-Text 'sk_combat.lua' 'phase == ActionExecutor.PHASE.WAITING_START' 'pre-cast window interruption fence'
Require-Text 'sk_combat.lua' 'phase == ActionExecutor.PHASE.RUNNING' 'running cast interruption fence'
Require-Text 'sk_combat.lua' "reason:find('peer_settling:', 1, true) == 1" 'Debuff claim-settle priority barrier'
Require-Text 'sk_combat.lua' "winner == 'debuff' and active == 'dps'" 'Debuff replaces queued DPS'
Require-Text 'sk_combat.lua' "'debuff_after_cast'" 'Debuff defers after mutation boundary'
Require-Text 'utils/domain_orchestrator.lua' 'host:withdrawLeaseRequest(reason)' 'queued domain replacement withdraws without tokenless release'
Require-Text 'sk_dps.lua' "workflow = 'dps_standoff_cast'" 'DPS-owned standoff and exact cast workflow'
Require-Text 'sk_dps.lua' 'module.domainKillAuthorized == true' 'Tank-primary standoff combat authorization'
Require-Text 'sk_dps.lua' 'CasterAssist.getStandoffNeed(' 'standoff independent of melee Assist mode'
Require-Text 'sk_assist.lua' 'The setting alone' 'standoff setting does not enable Assist attack/stick'
Require-Text 'sk_dps.lua' 'standoff_cast_issued' 'standoff movement retains lease through exact cast'
Require-Text 'automation/caster_assist.lua' "reason == 'initial_position'" 'leased initial standoff positioning'
Require-Text 'automation/caster_assist.lua' "return false, 'outside_minimum'" 'standoff never moves inward toward distant targets'
Require-Text 'automation/cc.lua' 'function M.hasLoadedMezSpell' 'active spell-set mez capability gate'
Require-Text 'automation/cc.lua' 'spell.HasSPA(31)() == true' 'SPA-based mez capability detection'
Require-Text 'sk_cc.lua' "'no_loaded_mez_spell'" 'CC worker capability short circuit'
Require-Text 'sk_cc.lua' 'if not self.componentMode and not self.currentRequestId' 'legacy-only CC engine orphan recovery'
Require-Text 'automation/cc.lua' "'sole_hater_hold'" 'single-hater mez hold'
Require-Text 'utils/claim_ledger.lua' 'Paths.getClaimLedgerPath()' 'claim ledger canonical SideKick-Next path'
Require-Text 'utils/paths.lua' 'function M.getClaimLedgerPath()' 'claim ledger path provider'
Require-Text 'utils/paths.lua' 'function M.normalize(path)' 'canonical cross-platform path separators'
Require-Text 'utils/safe_write.lua' 'Paths.ensureDir(parent)' 'atomic writer parent-directory guarantee'
Require-Text 'utils/safe_write.lua' 'if not dirOk then' 'atomic writer treats nil ensureDir returns as failure'
Require-Text 'utils/safe_write.lua' 'openWriteWithRetry' 'atomic writer retries ENOENT-after-mkdir on Windows'
Reject-Text 'utils/safe_write.lua' 'mq.delay(' 'atomic writer must not yield the caller'

# Companion damage feed wire contract: consumer subscribes to mailbox
# 'companion_events', filters on payload.sender, skips heal + incoming (this
# module is outgoing-only), and stops registering its own mq.event handlers
# when the feed is active. Producer side lives in F:\lua\companion.
Require-Text 'utils/damage_events.lua' "COMPANION_MAILBOX = 'companion_events'" 'companion feed mailbox constant'
Require-Text 'utils/damage_events.lua' 'function M.setCompanionFeedEnabled' 'companion feed opt-in entrypoint'
Require-Text 'utils/damage_events.lua' "content.sender or ''" 'companion feed filters on sender identity'
Require-Text 'utils/damage_events.lua' 'if content.incoming == true or content.kind ==' 'companion feed skips incoming + heal'
Require-Text 'utils/damage_events.lua' 'if _scope then M.unregisterEvents() end' 'companion feed unregisters local parser to avoid double-counting'
Require-Text 'registry.lua' 'UseCompanionDamageFeed' 'companion damage feed setting registered'

# Legacy tiered-healer surface: removed entirely — Healing Intelligence is the
# only heal path for CLR/DRU/SHM/PAL, per-character thresholds live in
# healing/config_<Server>_<Character>.lua, and there was no non-HI runtime path.
Reject-Text 'registry.lua' "PriorityHealing =" 'legacy tiered-healer PriorityHealing key'
Reject-Text 'registry.lua' "MainHealPoint =" 'legacy tiered-healer MainHealPoint key'
Reject-Text 'registry.lua' "BigHealPoint =" 'legacy tiered-healer BigHealPoint key'
Reject-Text 'registry.lua' "GroupHealPoint =" 'legacy tiered-healer GroupHealPoint key'
Reject-Text 'registry.lua' "GroupInjureCnt =" 'legacy tiered-healer GroupInjureCnt key'
Reject-Text 'registry.lua' "HealWatchMA =" 'legacy tiered-healer HealWatchMA key'
Reject-Text 'registry.lua' "HealXTargetEnabled =" 'legacy tiered-healer HealXTargetEnabled key'
Reject-Text 'registry.lua' "HealXTargetSlots =" 'legacy tiered-healer HealXTargetSlots key'
Reject-Text 'registry.lua' "HealUseHoTs =" 'legacy tiered-healer HealUseHoTs key'
Reject-Text 'registry.lua' "HealHoTMinSeconds =" 'legacy tiered-healer HealHoTMinSeconds key'
Reject-Text 'registry.lua' "PetHealPoint =" 'dead registry PetHealPoint key (runtime uses Config.petHealMinPct)'
Reject-Text 'registry.lua' "HealCoordinateActors =" 'dead registry HealCoordinateActors key'
Reject-Text 'registry.lua' "HealTrackHoTsViaActors =" 'dead registry HealTrackHoTsViaActors key'
Reject-Text 'ui/settings/tab_healing.lua' 'HealXTargetSlots' 'legacy tiered-healer XTarget UI'
Reject-Text 'ui/settings/tab_healing.lua' 'MainHealPoint' 'legacy tiered-healer heal-points UI'
Reject-Text 'ui/settings/tab_healing.lua' 'HealUseHoTs' 'legacy tiered-healer HoTs UI'
Reject-Text 'utils/ini_importer.lua' "'HealXTargetEnabled'" 'legacy tiered-healer XTarget INI import'
Reject-Text 'utils/ini_importer.lua' "'MainHealPoint'" 'legacy tiered-healer threshold INI import'
Reject-Text 'healing/ui/settings.lua' 'squishyCoveragePct' 'dead squishy-coverage advanced slider'
Reject-Text 'healing/ui/settings.lua' 'hotRefreshBufferSec' 'dead HoT-refresh-buffer advanced slider'
Reject-Text 'healing/ui/settings.lua' 'burstThresholdSigma' 'decoy burst-threshold advanced slider'
Reject-Text 'healing/config.lua' 'squishyCoveragePct' 'dead squishy-coverage default'
Reject-Text 'utils/claim_ledger.lua' "mq.configDir or 'config') .. '/SideKick'" 'production claim-ledger path'
Reject-Text 'utils/throttled_log.lua' 'In-game echo disabled' 'disabled throttled logger'
Require-Text 'sk_coordinator.lua' '[SK-Watchdog]' 'stale worker console breadcrumb'
Require-Regex 'sk_coordinator.lua' "elseif heartbeat then[\s\S]{0,900}printf\('\\ar\[SK-Watchdog\]" 'watchdog breadcrumb inside observed-heartbeat branch'
Require-Text 'sk_coordinator.lua' 'attemptRestart owns its bounded' 'EXITED worker logging delegated to restart throttle'
Require-Text 'ui/settings/tab_pull.lua' 'local _, clicked = imgui.Selectable(m, sel)' 'Pull mode combo click result'
Require-Text 'ui/settings/tab_pull.lua' 'local _, clicked = imgui.Selectable(id, sel)' 'Pull ability combo click result'
Require-Text 'ui/spell_set_editor.lua' 'local _, clicked = imgui.Selectable(name, isSelected)' 'spell-set combo click result'
Require-Text 'ui/components/data_table.lua' 'local _, clicked = imgui.Selectable(' 'data-table row click result'
Require-Text 'ui/components/demo.lua' 'local _, clicked = imgui.Selectable(name, name == State.themeName)' 'theme combo click result'
Require-Text 'utils/claim_ledger.lua' 'local _, clicked = imgui.Selectable(label, isSel)' 'claim-session combo click result'
Require-Text 'ui/components/search_input.lua' 'local _, clicked = imgui.Selectable(matchStr, false)' 'search suggestion click result'
Require-Text 'ui/components/search_input.lua' 'local _, clicked = imgui.Selectable(ft, i == typeIdx)' 'search filter combo click result'
Reject-Text 'test_eq_classic_ui.lua' 'if ImGui.Selectable(p.name, selected)' 'classic UI selected-state return misuse'

# Cross-file: every Actors.publish/ActorsCoordinator.publish/M.publish topic literal
# used anywhere in the tree must have a matching entry in TOPIC_CONTRACTS. Catches
# the class of bug where a new topic is introduced without a routing scope declared
# (which would fail closed at runtime with 'unregistered_publish_topic:X').
function Assert-PublishTopicsRegistered {
    $script:checked++
    $coordinatorPath = 'utils/actors_coordinator.lua'
    $coordinator = Get-Content -LiteralPath $coordinatorPath -Raw
    $contractsBlock = [regex]::Match($coordinator,
        "local TOPIC_CONTRACTS\s*=\s*\{([\s\S]*?)\n\}")
    if (-not $contractsBlock.Success) {
        $script:failures.Add("${coordinatorPath}: TOPIC_CONTRACTS table not found")
        return
    }
    $registered = @{}
    foreach ($m in [regex]::Matches($contractsBlock.Groups[1].Value,
        "\['([^']+)'\]\s*=\s*\{\s*scope\s*=\s*'(fleet|same_script)'")) {
        $registered[$m.Groups[1].Value] = $m.Groups[2].Value
    }
    $publishRegex = [regex]"(?:Actors|ActorsCoordinator|module\.peerActors|self\.peerActors|self\.actorsCoordinator|M)\.publish\(\s*'([^']+)'"
    $scanPaths = Get-ChildItem -Path . -Recurse -Include *.lua `
        | Where-Object { $_.FullName -notmatch '\\tests\\' -and $_.FullName -notmatch '\\docs\\' }
    foreach ($file in $scanPaths) {
        $text = Get-Content -LiteralPath $file.FullName -Raw
        foreach ($m in $publishRegex.Matches($text)) {
            $topic = $m.Groups[1].Value
            if (-not $registered.ContainsKey($topic)) {
                $rel = Resolve-Path -LiteralPath $file.FullName -Relative
                $script:failures.Add("${rel}: publish topic '${topic}' not in TOPIC_CONTRACTS")
            }
        }
    }
}
Assert-PublishTopicsRegistered

# Cross-file: every topic in TOPIC_CONTRACTS should have at least one producer
# somewhere in the tree. A registered-but-unused topic is dead surface area —
# either the producer was removed or the contract was added speculatively; both
# want cleanup. Skips topics with an explicit dead-entry marker in the contract
# comment so intentional placeholders can opt out.
function Assert-RegisteredTopicsHaveProducer {
    $script:checked++
    $coordinatorPath = 'utils/actors_coordinator.lua'
    $coordinator = Get-Content -LiteralPath $coordinatorPath -Raw
    $contractsBlock = [regex]::Match($coordinator,
        "local TOPIC_CONTRACTS\s*=\s*\{([\s\S]*?)\n\}")
    if (-not $contractsBlock.Success) { return }
    $registered = @()
    foreach ($m in [regex]::Matches($contractsBlock.Groups[1].Value,
        "\['([^']+)'\]\s*=\s*\{[^}]*\},?\s*(?:--\s*(dead|dynamic)[^\r\n]*)?")) {
        # Skip topics explicitly marked dead (intentional placeholder) or
        # dynamic (published via a computed topic name that this text-based
        # scan cannot follow).
        if (-not $m.Groups[2].Success) { $registered += $m.Groups[1].Value }
    }
    $allLua = Get-ChildItem -Path . -Recurse -Include *.lua `
        | Where-Object { $_.FullName -notmatch '\\tests\\' -and $_.FullName -notmatch '\\docs\\' }
    $allText = ($allLua | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
    foreach ($topic in $registered) {
        $literal = "publish('" + $topic + "'"
        if (-not $allText.Contains($literal)) {
            $script:failures.Add("${coordinatorPath}: TOPIC_CONTRACTS['${topic}'] has no producer (mark ' -- dead' if intentional)")
        }
    }
}
Assert-RegisteredTopicsHaveProducer

# Per-worker heartbeat carries idleReason + idleSinceAt + lastActionAt so the
# per-character status HUD can render 'why isn't this worker acting?' without
# new actor sends. These fields piggyback on MODULE_HEARTBEAT cadence.
Require-Text 'sk_module_base.lua' "idleReason = not intentActive and intentReason or ''" 'heartbeat idle-reason field'
Require-Text 'sk_module_base.lua' 'lastActionAt = tonumber(self.lastActionAtMs)' 'heartbeat last-action timestamp'
Require-Text 'sk_module_base.lua' 'idleSinceAt = idleSinceAt' 'heartbeat idle-since timestamp'
Require-Text 'sk_module_base.lua' 'function self:setIntentReason' 'idle-reason transition timestamp helper'
Require-Regex 'sk_module_base.lua' "self\.lastFinishedAtMs = nowMs\(\)[\s\S]{0,300}self\.lastActionAtMs = self\.lastFinishedAtMs" 'last-action timestamp updated after finalization'
Reject-Text 'sk_module_base.lua' 'self.lastActionAtMs = nowMs()' 'last-action timestamp refresh inside finishAction'
Require-Text 'sk_coordinator.lua' "idleReason = tostring(content.idleReason" 'coordinator ingests heartbeat idle-reason'
Require-Text 'sk_coordinator.lua' 'idleSinceAt = tonumber(content.idleSinceAt)' 'coordinator ingests idle-since timestamp'
Require-Text 'sk_coordinator.lua' 'lastActionAt = tonumber(content.lastActionAt)' 'coordinator ingests last-action timestamp'
Require-Text 'sk_module_base.lua' 'recoveredRequestId = tostring(self.lastRecoveredRequestId' 'exact recovery receipt on heartbeat'
Require-Text 'sk_coordinator.lua' 'local recoveryReceiptMatches = lease' 'heartbeat recovery receipt matcher'
Require-Text 'sk_coordinator.lua' "noteSchedulerResult('recovered_heartbeat'" 'heartbeat-driven exact recovery acknowledgement'
Reject-Text 'utils/lease_scheduler.lua' 'function M:observeCleanHeartbeat' 'ambiguous clean-heartbeat recovery clear'
Require-Text 'utils/lease_scheduler.lua' 'rejectedRecoveryReports' 'reject-count tracking on recovering leases'
Require-Text 'utils/lease_scheduler.lua' 'STUCK_RECOVERY_MS' 'time-bounded stuck-recovery force-clear threshold'
Require-Text 'utils/lease_scheduler.lua' 'stuckRecoveryClears' 'stuck-recovery force-clear metric'
Require-Text 'ui/worker_status_hud.lua' 'function M.render' 'per-character worker status HUD entry point'
Require-Text 'ui/worker_status_hud.lua' "mq.imgui.init('SideKickWorkerStatus', M.render)" 'independent worker HUD ImGui callback'
Require-Text 'ui/worker_status_hud.lua' 'renderOk, renderError = xpcall(renderRows, debug.traceback)' 'worker HUD render isolation'
Require-Text 'ui/worker_status_hud.lua' "tostring(diag.workerSessionId or '') ~= ''" 'HUD explicit heartbeat-presence check'
Require-Text 'ui/worker_status_hud.lua' 'if not imgui.BeginTable' 'HUD guarded BeginTable lifecycle'
Require-Text 'ui/worker_status_hud.lua' 'math.max(0, now - idleSinceAt)' 'HUD idle-duration clock'
Require-Text 'ui/worker_status_hud.lua' "tostring(lease.holderModule or '') == tostring(spec.module)" 'HUD active lease-holder classification'
Reject-Text 'ui/worker_status_hud.lua' 'local idleAge = hbAge' 'heartbeat age reused as idle duration'
Require-Text 'SideKick.lua' "'sidekick-next.ui.worker_status_hud'" 'worker status HUD lazy-registered in UI process'
Require-Text 'SideKick.lua' 'LZ.getWorkerStatusHud()' 'worker status HUD initialized outside shared imgui loop'
Reject-Text 'SideKick.lua' 'LZ.getWorkerStatusHud() if M then M.render()' 'worker status HUD coupled to shared imgui loop'
Require-Text 'registry.lua' 'WorkerStatusHUDVisible' 'worker status HUD toggle setting'
Require-Text 'SideKick.lua' 'local mainEnabled = settings.SideKickMainEnabled == true' 'opt-in main command-bar visibility'
Require-Text 'ui/settings/tab_ui.lua' 'local mainEnabled = settings.SideKickMainEnabled == true' 'main command-bar checkbox default'
Require-Text 'SideKick.lua' 'Core.Settings.SideKickMainEnabled == true and State.open' 'dock signal gated by visible main command bar'
Require-Text 'utils/actors_coordinator.lua' "sendToGroupTarget({ id = 'sidekick:docked', docked = false })" 'immediate undocked transition'
Require-Text 'utils/core.lua' 'function Core.isPrimaryWriter()' 'settings writer ownership exposed to shared-process consumers'
Require-Text 'sk_lib.lua' 'if not primaryWriter and core.load then pcall(core.load) end' 'supervisor cannot reload primary UI settings writer'
Reject-Text 'sk_lib.lua' 'if core.load then pcall(core.load) end' 'unconditional shared-process settings reload'
Require-Text 'sk_module_base.lua' "self:withdrawLeaseRequest('superseded_by_recovery')" 'pending request tombstoned before recovery handoff'
Require-Text 'sk_module_base.lua' "kind = 'recovery_cleanup'," 'dedicated recovery action'
Require-Text 'sk_module_base.lua' 'component = self.domainRecoveryComponent,' 'consolidated recovery routed to dirty component'
Reject-Text 'sk_module_base.lua' 'self.currentAction = self.currentAction or {' 'normal action reused as recovery cleanup'
Require-Text 'sk_chase.lua' '_intent = self.currentRequestId and not ownsCurrent' 'queued Chase action retained through request refresh'
Require-Text 'sk_chase.lua' "driveCleanup(self, action, 'slice_complete', false)" 'normal Chase slice completion without timeout backoff'
Require-Text 'sk_chase.lua' "reason == 'arrived' or reason == 'slice_complete'" 'successful Chase slice resets failure backoff'
Require-Text 'sk_chase.lua' 'or moved >= 1.5' 'moving follower counts as Chase progress'
Require-Text 'sk_chase.lua' 'if stalledForMs < STALL_CONFIRM_MS then' 'sustained Chase stall confirmation'
Require-Text 'sk_coordinator.lua' "recoveredRequestId == tostring(lease.requestId or '')" 'recovery heartbeat exact request match'
Require-Text 'sk_coordinator.lua' "recoveredToken == tostring(lease.token or '')" 'recovery heartbeat exact token match'

Write-Output "architecture_invariants_test: $checked checks, $($failures.Count) failures"
$failures | ForEach-Object { Write-Output $_ }
if ($failures.Count -gt 0) { exit 1 }
