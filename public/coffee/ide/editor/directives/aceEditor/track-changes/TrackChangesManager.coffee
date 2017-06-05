define [
	"ace/ace"
	"utils/EventEmitter"
	"ide/colors/ColorManager"
	"ide/editor/AceShareJsCodec"
], (_, EventEmitter, ColorManager, AceShareJsCodec) ->
	class TrackChangesManager
		Range = ace.require("ace/range").Range
		
		constructor: (@$scope, @editor, @element) ->
			window.trackChangesManager ?= @

			@$scope.$watch "trackChanges", (track_changes) =>
				return if !track_changes?
				@setTrackChanges(track_changes)
			
			@$scope.$watch "sharejsDoc", (doc, oldDoc) =>
				return if !doc?
				if oldDoc?
					@disconnectFromDoc(oldDoc)
				@connectToDoc(doc)
			
			@$scope.$on "comment:add", (e, thread_id, offset, length) =>
				@addCommentToSelection(thread_id, offset, length)

			@$scope.$on "comment:select_line", (e) =>
				@selectLineIfNoSelection()
			
			@$scope.$on "changes:accept", (e, change_ids) =>
				@acceptChangeIds(change_ids)

			@$scope.$on "changes:reject", (e, change_ids) =>
				@rejectChangeIds(change_ids)
			
			@$scope.$on "comment:remove", (e, comment_id) =>
				@removeCommentId(comment_id)
			
			@$scope.$on "comment:resolve_threads", (e, thread_ids) =>
				@hideCommentsByThreadIds(thread_ids)
			
			@$scope.$on "comment:unresolve_thread", (e, thread_id) =>
				@showCommentByThreadId(thread_id)
			
			@$scope.$on "review-panel:recalculate-screen-positions", () =>
				@recalculateReviewEntriesScreenPositions()

			changingSelection = false
			onChangeSelection = () =>
				# Deletes can send about 5 changeSelection events, so
				# just act on the last one.
				if !changingSelection
					changingSelection = true
					@$scope.$evalAsync () =>
						changingSelection = false
						@updateFocus()
			
			onResize = () =>
				@recalculateReviewEntriesScreenPositions()

			onChangeSession = (e) =>
				@clearAnnotations()
				@redrawAnnotations()
				@editor.session.on "changeScrollTop", onChangeScroll

			_scrollTimeout = null
			onChangeScroll = () =>
				if _scrollTimeout?
					return
				else
					_scrollTimeout = setTimeout () =>
						@recalculateVisibleEntries()
						@$scope.$apply()
						_scrollTimeout = null
					, 200

			@_resetCutState()
			onCut = () => @onCut()
			onPaste = () => @onPaste()

			bindToAce = () =>
				@editor.on "changeSelection", onChangeSelection
				@editor.on "change", onChangeSelection # Selection also moves with updates elsewhere in the document
				@editor.on "changeSession", onChangeSession
				@editor.on "cut", onCut
				@editor.on "paste", onPaste
				@editor.renderer.on "resize", onResize

			unbindFromAce = () =>
				@editor.off "changeSelection", onChangeSelection
				@editor.off "change", onChangeSelection
				@editor.off "changeSession", onChangeSession
				@editor.off "cut", onCut
				@editor.off "paste", onPaste
				@editor.renderer.off "resize", onResize

			@$scope.$watch "trackChangesEnabled", (enabled) =>
				return if !enabled?
				if enabled
					bindToAce()
				else
					unbindFromAce()
		
		disconnectFromDoc: (doc) ->
			@changeIdToMarkerIdMap = {}
			doc.off "ranges:clear"
			doc.off "ranges:redraw"
			doc.off "ranges:dirty"

		setTrackChanges: (value) ->
			if value
				@$scope.sharejsDoc?.track_changes_as = window.user.id or "anonymous"
			else
				@$scope.sharejsDoc?.track_changes_as = null
		
		connectToDoc: (doc) ->
			@rangesTracker = doc.ranges
			@setTrackChanges(@$scope.trackChanges)
			
			doc.on "ranges:dirty", () =>
				@updateAnnotations()
			doc.on "ranges:clear", () =>
				@clearAnnotations()
			doc.on "ranges:redraw", () =>
				@redrawAnnotations()
		
		clearAnnotations: () ->
			session = @editor.getSession()
			for change_id, markers of @changeIdToMarkerIdMap
				for marker_name, marker_id of markers
					session.removeMarker marker_id
			@changeIdToMarkerIdMap = {}

		redrawAnnotations: () ->
			for change in @rangesTracker.changes
				if change.op.i?
					@_onInsertAdded(change)
				else if change.op.d?
					@_onDeleteAdded(change)

			for comment in @rangesTracker.comments
				@_onCommentAdded(comment)
			
			@broadcastChange()
		
		_doneUpdateThisLoop: false
		_pendingUpdates: false
		updateAnnotations: () ->
			# Doc updates with multiple ops, like search/replace or block comments
			# will call this with every individual op in a single event loop. So only
			# do the first this loop, then schedule an update for the next loop for the rest.
			if !@_doneUpdateThisLoop
				@_doUpdateAnnotations()
				@_doneUpdateThisLoop = true
				setTimeout () =>
					if @_pendingUpdates
						@_doUpdateAnnotations()
					@_doneUpdateThisLoop = false
					@_pendingUpdates = false
			else
				@_pendingUpdates = true

		_doUpdateAnnotations: () ->
			dirty = @rangesTracker.getDirtyState()
			
			updateMarkers = false
			
			for id, change of dirty.change.added
				if change.op.i?
					@_onInsertAdded(change)
				else if change.op.d?
					@_onDeleteAdded(change)
			for id, change of dirty.change.removed
				if change.op.i?
					@_onInsertRemoved(change)
				else if change.op.d?
					@_onDeleteRemoved(change)
			for id, change of dirty.change.moved
				updateMarkers = true
				@_onChangeMoved(change)
				
			for id, comment of dirty.comment.added
				@_onCommentAdded(comment)
			for id, comment of dirty.comment.removed
				@_onCommentRemoved(comment)
			for id, comment of dirty.comment.moved
				updateMarkers = true
				@_onCommentMoved(comment)
			
			@rangesTracker.resetDirtyState()
			if updateMarkers
				@editor.renderer.updateBackMarkers()
			@broadcastChange()

		addComment: (offset, content, thread_id) ->
			op = { c: content, p: offset, t: thread_id }
			# @rangesTracker.applyOp op # Will apply via sharejs
			@$scope.sharejsDoc.submitOp op
		
		addCommentToSelection: (thread_id, offset, length) ->
			start = @_shareJsOffsetToAcePosition(offset)
			end = @_shareJsOffsetToAcePosition(offset + length)
			range = new Range(start.row, start.column, end.row, end.column)
			content = @editor.session.getTextRange(range)
			@addComment(offset, content, thread_id)
		
		selectLineIfNoSelection: () ->
			if @editor.selection.isEmpty()
				@editor.selection.selectLine()
		
		acceptChangeIds: (change_ids) ->
			@rangesTracker.removeChangeIds(change_ids)
			@updateAnnotations()

		rejectChangeIds: (change_ids) ->
			session = @editor.getSession()
			# This will log changes grabbed before we do any work; all should be present.
			console.log @rangesTracker.getChanges(change_ids)
			for id in change_ids
				change = @rangesTracker.getChange(id)
				# This will log changes grabbed as we reject stuff; if we have adjacent inserts and deletes, some will be missing.
				console.log change?.op
				if change? 
					if change.op.d?
						content = change.op.d
						position = @_shareJsOffsetToAcePosition(change.op.p)
						session.$fromReject = true # Tell track changes to cancel out delete
						session.insert(position, content)
						session.$fromReject = false
					else if change.op.i?
						start = @_shareJsOffsetToAcePosition(change.op.p)
						end = @_shareJsOffsetToAcePosition(change.op.p + change.op.i.length)
						editor_text = session.getDocument().getTextRange({start, end})
						if editor_text != change.op.i
							throw new Error("Op to be removed (#{JSON.stringify(change.op)}), does not match editor text, '#{editor_text}'")
						session.$fromReject = true
						session.remove({start, end})
						session.$fromReject = false
					else
						throw new Error("unknown change: #{JSON.stringify(change)}")

			# changes = @rangesTracker.getChanges(change_ids)
			# return if changes.length == 0
			# session = @editor.getSession()
			# for change in changes
			# 	if change.op.d?
			# 		content = change.op.d
			# 		position = @_shareJsOffsetToAcePosition(change.op.p)
			# 		session.$fromReject = true # Tell track changes to cancel out delete
			# 		session.insert(position, content)
			# 		session.$fromReject = false
			# 	else if change.op.i?
			# 		start = @_shareJsOffsetToAcePosition(change.op.p)
			# 		end = @_shareJsOffsetToAcePosition(change.op.p + change.op.i.length)
			# 		editor_text = session.getDocument().getTextRange({start, end})
			# 		if editor_text != change.op.i
			# 			throw new Error("Op to be removed (#{JSON.stringify(change.op)}), does not match editor text, '#{editor_text}'")
			# 		session.$fromReject = true
			# 		session.remove({start, end})
			# 		session.$fromReject = false
			# 	else
			# 		throw new Error("unknown change: #{JSON.stringify(change)}")

		removeCommentId: (comment_id) ->
			@rangesTracker.removeCommentId(comment_id)
			@updateAnnotations()

		hideCommentsByThreadIds: (thread_ids) ->
			resolve_ids = {}
			for id in thread_ids
				resolve_ids[id] = true
			for comment in @rangesTracker?.comments or []
				if resolve_ids[comment.op.t]
					@_onCommentRemoved(comment)
			@broadcastChange()
			
		showCommentByThreadId: (thread_id) ->
			for comment in @rangesTracker?.comments or []
				if comment.op.t == thread_id
					@_onCommentAdded(comment)
			@broadcastChange()

		_resetCutState: () ->
			@_cutState = {
				text: null
				comments: []
				docId: null
			}

		onCut: () ->
			@_resetCutState()
			selection = @editor.getSelectionRange()
			selection_start = @_aceRangeToShareJs(selection.start)
			selection_end = @_aceRangeToShareJs(selection.end)
			@_cutState.text = @editor.getSelectedText()
			@_cutState.docId = @$scope.docId
			for comment in @rangesTracker.comments
				comment_start = comment.op.p
				comment_end = comment_start + comment.op.c.length
				if selection_start <= comment_start and comment_end <= selection_end
					@_cutState.comments.push {
						offset: comment.op.p - selection_start
						text: comment.op.c
						comment: comment
					}

		onPaste: () =>
			@editor.once "change", (change) =>
				return if change.action != "insert"
				pasted_text = change.lines.join("\n")
				paste_offset = @_aceRangeToShareJs(change.start)
				# We have to wait until the change has been processed by the range tracker, 
				# since if we move the ops into place beforehand, they will be moved again
				# when the changes are processed by the range tracker. This ranges:dirty
				# event is fired after the doc has applied the changes to the range tracker.
				@$scope.sharejsDoc.on "ranges:dirty.paste", () =>
					@$scope.sharejsDoc.off "ranges:dirty.paste" # Doc event emitter uses namespaced events
					if pasted_text == @_cutState.text and @$scope.docId == @_cutState.docId
						for {comment, offset, text} in @_cutState.comments
							op = { c: text, p: paste_offset + offset, t: comment.id }
							@$scope.sharejsDoc.submitOp op # Resubmitting an existing comment op (by thread id) will move it
					@_resetCutState()
					# Check that comments still match text. Will throw error if not.
					@rangesTracker.validate(@editor.getValue())

		checkMapping: () ->
			# TODO: reintroduce this check
			session = @editor.getSession()

			# Make a copy of session.getMarkers() so we can modify it
			markers = {}
			for marker_id, marker of session.getMarkers()
				markers[marker_id] = marker

			expected_markers = []
			for change in @rangesTracker.changes
				if @changeIdToMarkerIdMap[change.id]?
					op = change.op
					{background_marker_id, callout_marker_id} = @changeIdToMarkerIdMap[change.id]
					start = @_shareJsOffsetToAcePosition(op.p)
					if op.i?
						end = @_shareJsOffsetToAcePosition(op.p + op.i.length)
					else if op.d?
						end = start
					expected_markers.push { marker_id: background_marker_id, start, end }
					expected_markers.push { marker_id: callout_marker_id, start, end: start }
			
			for comment in @rangesTracker.comments
				if @changeIdToMarkerIdMap[comment.id]?
					{background_marker_id, callout_marker_id} = @changeIdToMarkerIdMap[comment.id]
					start = @_shareJsOffsetToAcePosition(comment.op.p)
					end = @_shareJsOffsetToAcePosition(comment.op.p + comment.op.c.length)
					expected_markers.push { marker_id: background_marker_id, start, end }
					expected_markers.push { marker_id: callout_marker_id, start, end: start }
			
			for {marker_id, start, end} in expected_markers
				marker = markers[marker_id]
				delete markers[marker_id]
				if marker.range.start.row != start.row or
						marker.range.start.column != start.column or
						marker.range.end.row != end.row or
						marker.range.end.column != end.column
					console.error "Change doesn't match marker anymore", {change, marker, start, end}
			
			for marker_id, marker of markers
				if marker.clazz.match("track-changes")
					console.error "Orphaned ace marker", marker
		
		updateFocus: () ->
			selection = @editor.getSelectionRange()
			selection_start = @_aceRangeToShareJs(selection.start)
			selection_end = @_aceRangeToShareJs(selection.end)
			entries = @_getCurrentDocEntries()
			is_selection = (selection_start != selection_end)
			@$scope.$emit "editor:focus:changed", selection_start, selection_end, is_selection
		
		broadcastChange: () ->
			@$scope.$emit "editor:track-changes:changed", @$scope.docId
		
		recalculateReviewEntriesScreenPositions: () ->
			session = @editor.getSession()
			renderer = @editor.renderer
			{firstRow, lastRow} = renderer.layerConfig
			entries = @_getCurrentDocEntries()
			for entry_id, entry of entries or {}
				doc_position = @_shareJsOffsetToAcePosition(entry.offset)
				screen_position = session.documentToScreenPosition(doc_position.row, doc_position.column)
				y = screen_position.row * renderer.lineHeight
				entry.screenPos ?= {}
				entry.screenPos.y = y
				entry.docPos = doc_position
			@recalculateVisibleEntries()
			@$scope.$apply()

		recalculateVisibleEntries: () ->
			OFFSCREEN_ROWS = 20
			CULL_AFTER = 100 # With less than this number of entries, don't bother culling to avoid little UI jumps when scrolling.
			{firstRow, lastRow} = @editor.renderer.layerConfig
			entries = @_getCurrentDocEntries() or {}
			entriesLength = Object.keys(entries).length
			changed = false
			for entry_id, entry of entries
				old = entry.visible
				entry.visible = (entriesLength < CULL_AFTER) or (firstRow - OFFSCREEN_ROWS <= entry.docPos.row <= lastRow + OFFSCREEN_ROWS)
				if (entry.visible != old)
					changed = true
			if changed
				@$scope.$emit "editor:track-changes:visibility_changed"

		_getCurrentDocEntries: () ->
			doc_id = @$scope.docId
			entries = @$scope.reviewPanel.entries[doc_id] ?= {}
			return entries

		_makeZeroWidthRange: (position) ->
			ace_range = new Range(position.row, position.column, position.row, position.column)
			# Our delete marker is zero characters wide, but Ace doesn't draw ranges
			# that are empty. So we monkey patch the range to tell Ace it's not empty.
			# We do want to claim to be empty if we're off screen after clipping rows though.
			# This is the code we need to trick:
			#   var range = marker.range.clipRows(config.firstRow, config.lastRow);
			#   if (range.isEmpty()) continue;
			ace_range.clipRows = (first_row, last_row) ->
				@isEmpty = () ->
					first_row > @end.row or last_row < @start.row
				return @
			return ace_range
		
		_createCalloutMarker: (position, klass) ->
			session = @editor.getSession()
			callout_range = @_makeZeroWidthRange(position)
			markerLayer = @editor.renderer.$markerBack
			callout_marker_id = session.addMarker callout_range, klass, (html, range, left, top, config) ->
				markerLayer.drawSingleLineMarker(html, range, "track-changes-marker-callout #{klass} ace_start", config, 0, "width: auto; right: 0;")

		_onInsertAdded: (change) ->
			start = @_shareJsOffsetToAcePosition(change.op.p)
			end = @_shareJsOffsetToAcePosition(change.op.p + change.op.i.length)
			session = @editor.getSession()
			doc = session.getDocument()
			background_range = new Range(start.row, start.column, end.row, end.column)
			background_marker_id = session.addMarker background_range, "track-changes-marker track-changes-added-marker", "text"
			callout_marker_id = @_createCalloutMarker(start, "track-changes-added-marker-callout")
			@changeIdToMarkerIdMap[change.id] = { background_marker_id, callout_marker_id }

		_onDeleteAdded: (change) ->
			position = @_shareJsOffsetToAcePosition(change.op.p)
			session = @editor.getSession()
			doc = session.getDocument()

			markerLayer = @editor.renderer.$markerBack
			klass = "track-changes-marker track-changes-deleted-marker"
			background_range = @_makeZeroWidthRange(position)
			background_marker_id = session.addMarker background_range, klass, (html, range, left, top, config) ->
				markerLayer.drawSingleLineMarker(html, range, "#{klass} ace_start", config, 0, "")

			callout_marker_id = @_createCalloutMarker(position, "track-changes-deleted-marker-callout")
			@changeIdToMarkerIdMap[change.id] = { background_marker_id, callout_marker_id }
		
		_onInsertRemoved: (change) ->
			{background_marker_id, callout_marker_id} = @changeIdToMarkerIdMap[change.id]
			delete @changeIdToMarkerIdMap[change.id]
			session = @editor.getSession()
			session.removeMarker background_marker_id
			session.removeMarker callout_marker_id
		
		_onDeleteRemoved: (change) ->
			{background_marker_id, callout_marker_id} = @changeIdToMarkerIdMap[change.id]
			delete @changeIdToMarkerIdMap[change.id]
			session = @editor.getSession()
			session.removeMarker background_marker_id
			session.removeMarker callout_marker_id
		
		_onCommentAdded: (comment) ->
			if @rangesTracker.resolvedThreadIds[comment.op.t]
				# Comment is resolved so shouldn't be displayed.
				return
			if !@changeIdToMarkerIdMap[comment.id]?
				# Only create new markers if they don't already exist
				start = @_shareJsOffsetToAcePosition(comment.op.p)
				end = @_shareJsOffsetToAcePosition(comment.op.p + comment.op.c.length)
				session = @editor.getSession()
				doc = session.getDocument()
				background_range = new Range(start.row, start.column, end.row, end.column)
				background_marker_id = session.addMarker background_range, "track-changes-marker track-changes-comment-marker", "text"
				callout_marker_id = @_createCalloutMarker(start, "track-changes-comment-marker-callout")
				@changeIdToMarkerIdMap[comment.id] = { background_marker_id, callout_marker_id }
		
		_onCommentRemoved: (comment) ->
			if @changeIdToMarkerIdMap[comment.id]?
				# Resolved comments may not have marker ids
				{background_marker_id, callout_marker_id} = @changeIdToMarkerIdMap[comment.id]
				delete @changeIdToMarkerIdMap[comment.id]
				session = @editor.getSession()
				session.removeMarker background_marker_id
				session.removeMarker callout_marker_id

		_aceRangeToShareJs: (range) ->
			lines = @editor.getSession().getDocument().getLines 0, range.row
			return AceShareJsCodec.aceRangeToShareJs(range, lines)

		_aceChangeToShareJs: (delta) ->
			lines = @editor.getSession().getDocument().getLines 0, delta.start.row
			return AceShareJsCodec.aceChangeToShareJs(delta, lines)
		
		_shareJsOffsetToAcePosition: (offset) ->
			lines = @editor.getSession().getDocument().getAllLines()
			return AceShareJsCodec.shareJsOffsetToAcePosition(offset, lines)
		
		_onChangeMoved: (change) ->
			start = @_shareJsOffsetToAcePosition(change.op.p)
			if change.op.i?
				end = @_shareJsOffsetToAcePosition(change.op.p + change.op.i.length)
			else
				end = start
			@_updateMarker(change.id, start, end)
		
		_onCommentMoved: (comment) ->
			start = @_shareJsOffsetToAcePosition(comment.op.p)
			end = @_shareJsOffsetToAcePosition(comment.op.p + comment.op.c.length)
			@_updateMarker(comment.id, start, end)
	
		_updateMarker: (change_id, start, end) ->
			return if !@changeIdToMarkerIdMap[change_id]?
			session = @editor.getSession()
			markers = session.getMarkers()
			{background_marker_id, callout_marker_id} = @changeIdToMarkerIdMap[change_id]
			if background_marker_id? and markers[background_marker_id]?
				background_marker = markers[background_marker_id]
				background_marker.range.start = start
				background_marker.range.end = end
			if callout_marker_id? and markers[callout_marker_id]?
				callout_marker = markers[callout_marker_id]
				callout_marker.range.start = start
				callout_marker.range.end = start

