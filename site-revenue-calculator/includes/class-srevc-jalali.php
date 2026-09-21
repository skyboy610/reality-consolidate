<?php
defined( 'ABSPATH' ) || exit;

class Srevc_Jalali {

	const MIN_YEAR = 1300;
	const MAX_YEAR = 1500;

	public static function month_names() {
		return array(
			1  => 'فروردین',
			2  => 'اردیبهشت',
			3  => 'خرداد',
			4  => 'تیر',
			5  => 'مرداد',
			6  => 'شهریور',
			7  => 'مهر',
			8  => 'آبان',
			9  => 'آذر',
			10 => 'دی',
			11 => 'بهمن',
			12 => 'اسفند',
		);
	}

	public static function month_name( $jm ) {
		$names = self::month_names();
		$jm    = (int) $jm;
		return isset( $names[ $jm ] ) ? $names[ $jm ] : '';
	}

	public static function g2j( $gy, $gm, $gd ) {
		$gy    = (int) $gy;
		$gm    = (int) $gm;
		$gd    = (int) $gd;
		$g_d_m = array( 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 );
		$gy2   = ( $gm > 2 ) ? ( $gy + 1 ) : $gy;
		$days  = 355666 + ( 365 * $gy ) + intdiv( $gy2 + 3, 4 ) - intdiv( $gy2 + 99, 100 ) + intdiv( $gy2 + 399, 400 ) + $gd + $g_d_m[ $gm - 1 ];
		$jy    = -1595 + ( 33 * intdiv( $days, 12053 ) );
		$days  = $days % 12053;
		$jy   += 4 * intdiv( $days, 1461 );
		$days  = $days % 1461;
		if ( $days > 365 ) {
			$jy  += intdiv( $days - 1, 365 );
			$days = ( $days - 1 ) % 365;
		}
		if ( $days < 186 ) {
			$jm = 1 + intdiv( $days, 31 );
			$jd = 1 + ( $days % 31 );
		} else {
			$jm = 7 + intdiv( $days - 186, 30 );
			$jd = 1 + ( ( $days - 186 ) % 30 );
		}
		return array( (int) $jy, (int) $jm, (int) $jd );
	}

	public static function j2g( $jy, $jm, $jd ) {
		$jy    = (int) $jy + 1595;
		$jm    = (int) $jm;
		$jd    = (int) $jd;
		$days  = -355668 + ( 365 * $jy ) + ( intdiv( $jy, 33 ) * 8 ) + intdiv( ( $jy % 33 ) + 3, 4 ) + $jd + ( ( $jm < 7 ) ? ( $jm - 1 ) * 31 : ( ( $jm - 7 ) * 30 ) + 186 );
		$gy    = 400 * intdiv( $days, 146097 );
		$days %= 146097;
		if ( $days > 36524 ) {
			--$days;
			$gy   += 100 * intdiv( $days, 36524 );
			$days %= 36524;
			if ( $days >= 365 ) {
				++$days;
			}
		}
		$gy   += 4 * intdiv( $days, 1461 );
		$days %= 1461;
		if ( $days > 365 ) {
			$gy  += intdiv( $days - 1, 365 );
			$days = ( $days - 1 ) % 365;
		}
		$gd    = $days + 1;
		$leap  = ( ( 0 === $gy % 4 && 0 !== $gy % 100 ) || 0 === $gy % 400 );
		$sal_a = array( 0, 31, $leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 );
		$gm    = 0;
		while ( $gm < 13 && $gd > $sal_a[ $gm ] ) {
			$gd -= $sal_a[ $gm ];
			++$gm;
		}
		return array( (int) $gy, (int) $gm, (int) $gd );
	}

	public static function is_leap( $jy ) {
		$g = self::j2g( $jy, 12, 30 );
		$r = self::g2j( $g[0], $g[1], $g[2] );
		return ( (int) $jy === $r[0] && 12 === $r[1] && 30 === $r[2] );
	}

	public static function days_in_month( $jy, $jm ) {
		$jm = (int) $jm;
		if ( $jm < 1 || $jm > 12 ) {
			return 0;
		}
		if ( $jm <= 6 ) {
			return 31;
		}
		if ( $jm <= 11 ) {
			return 30;
		}
		return self::is_leap( $jy ) ? 30 : 29;
	}

	public static function normalize_digits( $value ) {
		$persian = array( '۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹' );
		$arabic  = array( '٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩' );
		$latin   = array( '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' );
		$value   = str_replace( $persian, $latin, (string) $value );
		$value   = str_replace( $arabic, $latin, $value );
		return $value;
	}

	public static function parse( $value ) {
		$value = trim( self::normalize_digits( $value ) );
		if ( '' === $value ) {
			return false;
		}
		$value = str_replace( array( '-', '.', '\\' ), '/', $value );
		if ( ! preg_match( '/^(\d{4})\/(\d{1,2})\/(\d{1,2})$/', $value, $m ) ) {
			return false;
		}
		$jy = (int) $m[1];
		$jm = (int) $m[2];
		$jd = (int) $m[3];
		if ( $jy < self::MIN_YEAR || $jy > self::MAX_YEAR || $jm < 1 || $jm > 12 ) {
			return false;
		}
		if ( $jd < 1 || $jd > self::days_in_month( $jy, $jm ) ) {
			return false;
		}
		return array( $jy, $jm, $jd );
	}

	public static function to_gregorian_string( $jy, $jm, $jd ) {
		$g = self::j2g( $jy, $jm, $jd );
		return sprintf( '%04d-%02d-%02d', $g[0], $g[1], $g[2] );
	}

	public static function from_gregorian_string( $date ) {
		$parts = explode( '-', substr( (string) $date, 0, 10 ) );
		if ( 3 !== count( $parts ) ) {
			return false;
		}
		return self::g2j( (int) $parts[0], (int) $parts[1], (int) $parts[2] );
	}

	public static function format_gregorian_string( $date, $with_month_name = false ) {
		$j = self::from_gregorian_string( $date );
		if ( ! $j ) {
			return '';
		}
		if ( $with_month_name ) {
			return sprintf( '%d %s %d', $j[2], self::month_name( $j[1] ), $j[0] );
		}
		return sprintf( '%04d/%02d/%02d', $j[0], $j[1], $j[2] );
	}

	public static function today() {
		$now = current_time( 'Y-m-d' );
		return self::from_gregorian_string( $now );
	}
}
