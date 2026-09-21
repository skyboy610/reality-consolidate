( function () {
	'use strict';

	var config = window.srevcData || {};
	var months = config.months || [ 'فروردین', 'اردیبهشت', 'خرداد', 'تیر', 'مرداد', 'شهریور', 'مهر', 'آبان', 'آذر', 'دی', 'بهمن', 'اسفند' ];
	var weekdays = config.weekdays || [ 'ش', 'ی', 'د', 'س', 'چ', 'پ', 'ج' ];
	var todayJalali = config.today || { jy: 1400, jm: 1, jd: 1 };

	function div( a, b ) {
		return Math.trunc( a / b );
	}

	function g2j( gy, gm, gd ) {
		var gDm = [ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 ];
		var gy2 = gm > 2 ? gy + 1 : gy;
		var days = 355666 + ( 365 * gy ) + div( gy2 + 3, 4 ) - div( gy2 + 99, 100 ) + div( gy2 + 399, 400 ) + gd + gDm[ gm - 1 ];
		var jy = -1595 + ( 33 * div( days, 12053 ) );
		var jm;
		var jd;
		days = days % 12053;
		jy += 4 * div( days, 1461 );
		days = days % 1461;
		if ( days > 365 ) {
			jy += div( days - 1, 365 );
			days = ( days - 1 ) % 365;
		}
		if ( days < 186 ) {
			jm = 1 + div( days, 31 );
			jd = 1 + ( days % 31 );
		} else {
			jm = 7 + div( days - 186, 30 );
			jd = 1 + ( ( days - 186 ) % 30 );
		}
		return { jy: jy, jm: jm, jd: jd };
	}

	function j2g( jy, jm, jd ) {
		jy = jy + 1595;
		var days = -355668 + ( 365 * jy ) + ( div( jy, 33 ) * 8 ) + div( ( jy % 33 ) + 3, 4 ) + jd + ( jm < 7 ? ( jm - 1 ) * 31 : ( ( jm - 7 ) * 30 ) + 186 );
		var gy = 400 * div( days, 146097 );
		days = days % 146097;
		if ( days > 36524 ) {
			days = days - 1;
			gy += 100 * div( days, 36524 );
			days = days % 36524;
			if ( days >= 365 ) {
				days = days + 1;
			}
		}
		gy += 4 * div( days, 1461 );
		days = days % 1461;
		if ( days > 365 ) {
			gy += div( days - 1, 365 );
			days = ( days - 1 ) % 365;
		}
		var gd = days + 1;
		var leap = ( ( gy % 4 === 0 && gy % 100 !== 0 ) || gy % 400 === 0 );
		var salA = [ 0, 31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 ];
		var gm = 0;
		while ( gm < 13 && gd > salA[ gm ] ) {
			gd -= salA[ gm ];
			gm += 1;
		}
		return { gy: gy, gm: gm, gd: gd };
	}

	function isLeap( jy ) {
		var g = j2g( jy, 12, 30 );
		var r = g2j( g.gy, g.gm, g.gd );
		return r.jy === jy && r.jm === 12 && r.jd === 30;
	}

	function daysInMonth( jy, jm ) {
		if ( jm <= 6 ) {
			return 31;
		}
		if ( jm <= 11 ) {
			return 30;
		}
		return isLeap( jy ) ? 30 : 29;
	}

	function pad( value ) {
		return value < 10 ? '0' + value : '' + value;
	}

	function toLatin( value ) {
		var persian = [ '۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹' ];
		var arabic = [ '٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩' ];
		var out = String( value );
		for ( var i = 0; i < 10; i++ ) {
			out = out.split( persian[ i ] ).join( i ).split( arabic[ i ] ).join( i );
		}
		return out;
	}

	function parseValue( value ) {
		var clean = toLatin( value ).trim().replace( /[-.\\]/g, '/' );
		var match = clean.match( /^(\d{4})\/(\d{1,2})\/(\d{1,2})$/ );
		if ( ! match ) {
			return null;
		}
		var jy = parseInt( match[ 1 ], 10 );
		var jm = parseInt( match[ 2 ], 10 );
		var jd = parseInt( match[ 3 ], 10 );
		if ( jm < 1 || jm > 12 || jd < 1 || jd > daysInMonth( jy, jm ) ) {
			return null;
		}
		return { jy: jy, jm: jm, jd: jd };
	}

	function formatValue( jy, jm, jd ) {
		return jy + '/' + pad( jm ) + '/' + pad( jd );
	}

	var picker = null;
	var activeInput = null;
	var viewYear = todayJalali.jy;
	var viewMonth = todayJalali.jm;

	function buildPicker() {
		var box = document.createElement( 'div' );
		box.className = 'srevc-picker';
		box.style.display = 'none';
		box.innerHTML =
			'<div class="srevc-picker-head">' +
			'<button type="button" class="srevc-picker-nav" data-srevc-nav="prev">&#8249;</button>' +
			'<span class="srevc-picker-title"></span>' +
			'<button type="button" class="srevc-picker-nav" data-srevc-nav="next">&#8250;</button>' +
			'</div>' +
			'<div class="srevc-picker-weekdays"></div>' +
			'<div class="srevc-picker-days"></div>' +
			'<div class="srevc-picker-foot">' +
			'<button type="button" class="srevc-picker-today">' + ( config.todayLabel || 'امروز' ) + '</button>' +
			'<button type="button" class="srevc-picker-clear">' + ( config.clearLabel || 'پاک کردن' ) + '</button>' +
			'</div>';

		var weekRow = box.querySelector( '.srevc-picker-weekdays' );
		weekdays.forEach( function ( day ) {
			var cell = document.createElement( 'span' );
			cell.textContent = day;
			weekRow.appendChild( cell );
		} );

		box.addEventListener( 'mousedown', function ( event ) {
			event.preventDefault();
		} );

		box.addEventListener( 'click', function ( event ) {
			var nav = event.target.getAttribute( 'data-srevc-nav' );
			if ( nav ) {
				shiftMonth( 'next' === nav ? 1 : -1 );
				return;
			}
			if ( event.target.classList.contains( 'srevc-picker-today' ) ) {
				applyDate( todayJalali.jy, todayJalali.jm, todayJalali.jd );
				return;
			}
			if ( event.target.classList.contains( 'srevc-picker-clear' ) ) {
				if ( activeInput ) {
					activeInput.value = '';
				}
				hidePicker();
				return;
			}
			var day = event.target.getAttribute( 'data-srevc-day' );
			if ( day ) {
				applyDate( viewYear, viewMonth, parseInt( day, 10 ) );
			}
		} );

		document.body.appendChild( box );
		return box;
	}

	function shiftMonth( delta ) {
		viewMonth += delta;
		if ( viewMonth > 12 ) {
			viewMonth = 1;
			viewYear += 1;
		}
		if ( viewMonth < 1 ) {
			viewMonth = 12;
			viewYear -= 1;
		}
		renderDays();
	}

	function applyDate( jy, jm, jd ) {
		if ( ! activeInput ) {
			return;
		}
		activeInput.value = formatValue( jy, jm, jd );
		var form = activeInput.form;
		if ( form ) {
			var custom = form.querySelector( 'input[name="srevc_range"][value="custom"]' );
			if ( custom ) {
				custom.checked = true;
				var chips = form.querySelectorAll( '.srevc-chip' );
				Array.prototype.forEach.call( chips, function ( chip ) {
					chip.classList.remove( 'is-active' );
				} );
				if ( custom.parentNode && custom.parentNode.classList ) {
					custom.parentNode.classList.add( 'is-active' );
				}
			}
		}
		hidePicker();
	}

	function renderDays() {
		var title = picker.querySelector( '.srevc-picker-title' );
		var grid = picker.querySelector( '.srevc-picker-days' );
		title.textContent = months[ viewMonth - 1 ] + ' ' + viewYear;
		grid.innerHTML = '';

		var first = j2g( viewYear, viewMonth, 1 );
		var firstDate = new Date( first.gy, first.gm - 1, first.gd );
		var offset = ( firstDate.getDay() + 1 ) % 7;
		var total = daysInMonth( viewYear, viewMonth );
		var selected = activeInput ? parseValue( activeInput.value ) : null;
		var i;

		for ( i = 0; i < offset; i++ ) {
			var blank = document.createElement( 'span' );
			blank.className = 'srevc-picker-day is-empty';
			grid.appendChild( blank );
		}

		for ( i = 1; i <= total; i++ ) {
			var cell = document.createElement( 'button' );
			cell.type = 'button';
			cell.className = 'srevc-picker-day';
			cell.setAttribute( 'data-srevc-day', i );
			cell.textContent = i;
			if ( todayJalali.jy === viewYear && todayJalali.jm === viewMonth && todayJalali.jd === i ) {
				cell.classList.add( 'is-today' );
			}
			if ( selected && selected.jy === viewYear && selected.jm === viewMonth && selected.jd === i ) {
				cell.classList.add( 'is-selected' );
			}
			grid.appendChild( cell );
		}
	}

	function showPicker( input ) {
		if ( ! picker ) {
			picker = buildPicker();
		}
		activeInput = input;
		var parsed = parseValue( input.value );
		viewYear = parsed ? parsed.jy : todayJalali.jy;
		viewMonth = parsed ? parsed.jm : todayJalali.jm;
		renderDays();

		var rect = input.getBoundingClientRect();
		picker.style.display = 'block';
		picker.style.top = ( rect.bottom + window.pageYOffset + 6 ) + 'px';
		var left = rect.left + window.pageXOffset;
		var maxLeft = window.pageXOffset + document.documentElement.clientWidth - picker.offsetWidth - 10;
		picker.style.left = Math.max( 10, Math.min( left, maxLeft ) ) + 'px';
	}

	function hidePicker() {
		if ( picker ) {
			picker.style.display = 'none';
		}
		activeInput = null;
	}

	function normalizeInput( input ) {
		var parsed = parseValue( input.value );
		if ( parsed ) {
			input.value = formatValue( parsed.jy, parsed.jm, parsed.jd );
			input.classList.remove( 'srevc-invalid' );
		} else if ( '' !== input.value.trim() ) {
			input.classList.add( 'srevc-invalid' );
		} else {
			input.classList.remove( 'srevc-invalid' );
		}
	}

	function bind() {
		var inputs = document.querySelectorAll( '[data-srevc-jalali]' );
		Array.prototype.forEach.call( inputs, function ( input ) {
			input.setAttribute( 'dir', 'ltr' );
			input.addEventListener( 'focus', function () {
				showPicker( input );
			} );
			input.addEventListener( 'click', function () {
				showPicker( input );
			} );
			input.addEventListener( 'blur', function () {
				normalizeInput( input );
			} );
			input.addEventListener( 'keydown', function ( event ) {
				if ( 'Escape' === event.key ) {
					hidePicker();
				}
			} );
		} );

		document.addEventListener( 'click', function ( event ) {
			if ( ! picker || 'none' === picker.style.display ) {
				return;
			}
			if ( picker.contains( event.target ) || ( activeInput && event.target === activeInput ) ) {
				return;
			}
			hidePicker();
		} );

		document.addEventListener( 'change', function ( event ) {
			if ( ! event.target.hasAttribute || ! event.target.hasAttribute( 'data-srevc-toggle-group' ) ) {
				return;
			}
			var group = event.target.closest ? event.target.closest( '.srevc-group' ) : null;
			if ( ! group ) {
				return;
			}
			var boxes = group.querySelectorAll( 'input[name="srevc_orders[]"]' );
			Array.prototype.forEach.call( boxes, function ( box ) {
				box.checked = event.target.checked;
			} );
		} );

		document.addEventListener( 'click', function ( event ) {
			var target = event.target.closest ? event.target.closest( '[data-srevc-confirm]' ) : null;
			if ( ! target ) {
				return;
			}
			if ( ! window.confirm( target.getAttribute( 'data-srevc-confirm' ) ) ) {
				event.preventDefault();
			}
		} );

		var chips = document.querySelectorAll( '.srevc-chip input[type="radio"]' );
		Array.prototype.forEach.call( chips, function ( radio ) {
			radio.addEventListener( 'change', function () {
				Array.prototype.forEach.call( document.querySelectorAll( '.srevc-chip' ), function ( chip ) {
					chip.classList.remove( 'is-active' );
				} );
				if ( radio.parentNode && radio.parentNode.classList ) {
					radio.parentNode.classList.add( 'is-active' );
				}
			} );
		} );
	}

	if ( 'loading' === document.readyState ) {
		document.addEventListener( 'DOMContentLoaded', bind );
	} else {
		bind();
	}
}() );
