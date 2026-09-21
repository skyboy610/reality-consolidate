<?php
defined( 'ABSPATH' ) || exit;

class Srevc_Range {

	public static function presets() {
		return array(
			'today'      => 'امروز',
			'yesterday'  => 'دیروز',
			'week'       => 'این هفته',
			'last_week'  => 'هفته گذشته',
			'month'      => 'این ماه',
			'last_month' => 'ماه گذشته',
			'last_30'    => '۳۰ روز اخیر',
			'year'       => 'امسال',
			'last_year'  => 'سال گذشته',
			'custom'     => 'بازه دلخواه',
		);
	}

	public static function today_gregorian() {
		return current_time( 'Y-m-d' );
	}

	public static function shift_days( $date, $days ) {
		$time = strtotime( $date . ' 12:00:00' );
		if ( false === $time ) {
			return $date;
		}
		return gmdate( 'Y-m-d', $time + ( (int) $days * DAY_IN_SECONDS ) );
	}

	public static function week_start( $date ) {
		$time = strtotime( $date . ' 12:00:00' );
		if ( false === $time ) {
			return $date;
		}
		$weekday = (int) gmdate( 'w', $time );
		$offset  = ( $weekday + 1 ) % 7;
		return self::shift_days( $date, -$offset );
	}

	public static function resolve( $preset, $custom_start = '', $custom_end = '' ) {
		$today = self::today_gregorian();
		$jt    = Srevc_Jalali::from_gregorian_string( $today );

		switch ( $preset ) {
			case 'today':
				$start = $today;
				$end   = $today;
				break;

			case 'yesterday':
				$start = self::shift_days( $today, -1 );
				$end   = $start;
				break;

			case 'week':
				$start = self::week_start( $today );
				$end   = $today;
				break;

			case 'last_week':
				$this_week = self::week_start( $today );
				$start     = self::shift_days( $this_week, -7 );
				$end       = self::shift_days( $this_week, -1 );
				break;

			case 'month':
				$start = Srevc_Jalali::to_gregorian_string( $jt[0], $jt[1], 1 );
				$end   = $today;
				break;

			case 'last_month':
				$jy = ( 1 === $jt[1] ) ? $jt[0] - 1 : $jt[0];
				$jm = ( 1 === $jt[1] ) ? 12 : $jt[1] - 1;
				$start = Srevc_Jalali::to_gregorian_string( $jy, $jm, 1 );
				$end   = Srevc_Jalali::to_gregorian_string( $jy, $jm, Srevc_Jalali::days_in_month( $jy, $jm ) );
				break;

			case 'last_30':
				$start = self::shift_days( $today, -29 );
				$end   = $today;
				break;

			case 'year':
				$start = Srevc_Jalali::to_gregorian_string( $jt[0], 1, 1 );
				$end   = $today;
				break;

			case 'last_year':
				$start = Srevc_Jalali::to_gregorian_string( $jt[0] - 1, 1, 1 );
				$end   = Srevc_Jalali::to_gregorian_string( $jt[0] - 1, 12, Srevc_Jalali::days_in_month( $jt[0] - 1, 12 ) );
				break;

			case 'custom':
			default:
				$parsed_start = Srevc_Jalali::parse( $custom_start );
				$parsed_end   = Srevc_Jalali::parse( $custom_end );
				if ( ! $parsed_start || ! $parsed_end ) {
					return new WP_Error( 'srevc_invalid_date', 'تاریخ شروع یا پایان معتبر نیست. قالب درست مانند ۱۴۰۴/۰۶/۰۱ است.' );
				}
				$start = Srevc_Jalali::to_gregorian_string( $parsed_start[0], $parsed_start[1], $parsed_start[2] );
				$end   = Srevc_Jalali::to_gregorian_string( $parsed_end[0], $parsed_end[1], $parsed_end[2] );
				break;
		}

		if ( strtotime( $start ) > strtotime( $end ) ) {
			$swap  = $start;
			$start = $end;
			$end   = $swap;
		}

		return array(
			'start' => $start,
			'end'   => $end,
		);
	}

	public static function label( $start, $end ) {
		$start_label = Srevc_Jalali::format_gregorian_string( $start, true );
		$end_label   = Srevc_Jalali::format_gregorian_string( $end, true );
		if ( $start === $end ) {
			return $start_label;
		}
		return $start_label . ' تا ' . $end_label;
	}
}
