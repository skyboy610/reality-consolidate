<?php
defined( 'ABSPATH' ) || exit;

class Srevc_Cleanup {

	const LOG_OPTION = 'srevc_delete_log';
	const LOG_LIMIT  = 200;
	const MAX_ORDERS = 3000;

	public static function manual_via() {
		$settings = srevc_get_settings();
		$list     = Srevc_Query::split_list( $settings['manual_via'] );
		if ( empty( $list ) ) {
			$list = array( 'admin' );
		}
		return array_map( 'strtolower', $list );
	}

	protected static function customer_key( $order ) {
		$user_id = (int) $order->get_customer_id();
		if ( $user_id > 0 ) {
			return 'u:' . $user_id;
		}
		$email = strtolower( trim( (string) $order->get_billing_email() ) );
		if ( '' !== $email ) {
			return 'e:' . $email;
		}
		$phone = preg_replace( '/\D+/', '', (string) $order->get_billing_phone() );
		if ( '' !== $phone ) {
			return 'p:' . $phone;
		}
		return '';
	}

	protected static function customer_name( $order ) {
		$name = trim( $order->get_billing_first_name() . ' ' . $order->get_billing_last_name() );
		if ( '' !== $name ) {
			return $name;
		}
		$user_id = (int) $order->get_customer_id();
		if ( $user_id > 0 ) {
			$user = get_userdata( $user_id );
			if ( $user ) {
				return $user->display_name;
			}
		}
		$email = (string) $order->get_billing_email();
		return '' !== $email ? $email : 'بدون نام';
	}

	protected static function items_summary( $order ) {
		$parts = array();
		foreach ( $order->get_items() as $item ) {
			$parts[] = $item->get_name() . ' ×' . $item->get_quantity();
			if ( count( $parts ) >= 3 ) {
				break;
			}
		}
		return implode( '، ', $parts );
	}

	protected static function order_data( $order ) {
		$created = $order->get_date_created();
		$local   = $created ? $created->date( 'Y-m-d' ) : '';
		$time    = $created ? $created->date( 'H:i' ) : '';
		$statuses = Srevc_Query::available_statuses();
		$status   = 'wc-' . $order->get_status();

		return array(
			'id'           => $order->get_id(),
			'number'       => $order->get_order_number(),
			'date'         => $local,
			'time'         => $time,
			'timestamp'    => $created ? $created->getTimestamp() : 0,
			'day_ts'       => '' !== $local ? (int) strtotime( $local . ' 12:00:00' ) : 0,
			'jalali'       => '' !== $local ? Srevc_Jalali::format_gregorian_string( $local, true ) : '',
			'customer'     => self::customer_name( $order ),
			'customer_key' => self::customer_key( $order ),
			'email'        => (string) $order->get_billing_email(),
			'total'        => (float) $order->get_total(),
			'status'       => $status,
			'status_label' => isset( $statuses[ $status ] ) ? $statuses[ $status ] : $order->get_status(),
			'created_via'  => strtolower( (string) $order->get_created_via() ),
			'payment'      => (string) $order->get_payment_method_title(),
			'coupons'      => implode( '، ', (array) $order->get_coupon_codes() ),
			'items'        => self::items_summary( $order ),
			'edit_url'     => $order->get_edit_order_url(),
		);
	}

	public static function find_groups( $start, $end, $window_days, $only_with_matches = false ) {
		$window_days = max( 0, min( 30, (int) $window_days ) );
		$fetch_from  = Srevc_Range::shift_days( $start, -( $window_days + 1 ) );
		$fetch_to    = Srevc_Range::shift_days( $end, $window_days + 1 );

		$orders = wc_get_orders(
			array(
				'limit'        => self::MAX_ORDERS,
				'status'       => array_keys( wc_get_order_statuses() ),
				'type'         => 'shop_order',
				'date_created' => $fetch_from . '...' . $fetch_to,
				'orderby'      => 'date',
				'order'        => 'DESC',
				'return'       => 'objects',
			)
		);

		if ( ! is_array( $orders ) ) {
			$orders = array();
		}

		$manual_via = self::manual_via();
		$all        = array();
		$by_key     = array();

		foreach ( $orders as $order ) {
			if ( ! is_a( $order, 'WC_Order' ) ) {
				continue;
			}
			$data  = self::order_data( $order );
			$all[] = $data;
			if ( '' !== $data['customer_key'] ) {
				$by_key[ $data['customer_key'] ][] = $data;
			}
		}

		$groups = array();

		foreach ( $all as $data ) {
			if ( ! in_array( $data['created_via'], $manual_via, true ) ) {
				continue;
			}
			if ( $data['date'] < $start || $data['date'] > $end ) {
				continue;
			}

			$matches = array();
			if ( '' !== $data['customer_key'] && isset( $by_key[ $data['customer_key'] ] ) ) {
				foreach ( $by_key[ $data['customer_key'] ] as $candidate ) {
					if ( $candidate['id'] === $data['id'] ) {
						continue;
					}
					if ( in_array( $candidate['created_via'], $manual_via, true ) ) {
						continue;
					}
					$gap = (int) round( abs( $candidate['day_ts'] - $data['day_ts'] ) / DAY_IN_SECONDS );
					if ( $gap > $window_days ) {
						continue;
					}
					$candidate['same_amount'] = ( abs( $candidate['total'] - $data['total'] ) < 0.01 );
					$candidate['day_gap']     = $gap;
					$matches[]                = $candidate;
				}
			}

			usort(
				$matches,
				function ( $a, $b ) {
					if ( $a['same_amount'] !== $b['same_amount'] ) {
						return $a['same_amount'] ? -1 : 1;
					}
					return $a['day_gap'] <=> $b['day_gap'];
				}
			);

			if ( $only_with_matches && empty( $matches ) ) {
				continue;
			}

			$groups[] = array(
				'admin'   => $data,
				'matches' => $matches,
			);
		}

		usort(
			$groups,
			function ( $a, $b ) {
				return $b['admin']['timestamp'] <=> $a['admin']['timestamp'];
			}
		);

		return array(
			'groups'  => $groups,
			'scanned' => count( $all ),
			'capped'  => ( count( $all ) >= self::MAX_ORDERS ),
		);
	}

	public static function delete_orders( $ids, $permanent = false ) {
		$deleted = 0;
		$failed  = 0;
		$entries = array();

		foreach ( (array) $ids as $id ) {
			$id    = absint( $id );
			$order = $id > 0 ? wc_get_order( $id ) : false;

			if ( ! $order || ! is_a( $order, 'WC_Order' ) ) {
				++$failed;
				continue;
			}

			$number   = $order->get_order_number();
			$total    = (float) $order->get_total();
			$customer = self::customer_name( $order );
			$result   = $order->delete( (bool) $permanent );

			if ( $result ) {
				++$deleted;
				$entries[] = array(
					'time'     => current_time( 'mysql' ),
					'order'    => $number,
					'id'       => $id,
					'total'    => $total,
					'customer' => $customer,
					'mode'     => $permanent ? 'permanent' : 'trash',
					'user'     => wp_get_current_user()->user_login,
					'status'   => 'success',
				);
			} else {
				++$failed;
				$entries[] = array(
					'time'     => current_time( 'mysql' ),
					'order'    => $number,
					'id'       => $id,
					'total'    => $total,
					'customer' => $customer,
					'mode'     => $permanent ? 'permanent' : 'trash',
					'user'     => wp_get_current_user()->user_login,
					'status'   => 'error',
				);
			}
		}

		if ( ! empty( $entries ) ) {
			self::add_log( $entries );
		}

		return array(
			'deleted' => $deleted,
			'failed'  => $failed,
		);
	}

	public static function add_log( $entries ) {
		$log = get_option( self::LOG_OPTION, array() );
		if ( ! is_array( $log ) ) {
			$log = array();
		}
		$log = array_merge( array_values( $entries ), $log );
		if ( count( $log ) > self::LOG_LIMIT ) {
			$log = array_slice( $log, 0, self::LOG_LIMIT );
		}
		update_option( self::LOG_OPTION, $log, false );
	}

	public static function get_log( $limit = 30 ) {
		$log = get_option( self::LOG_OPTION, array() );
		if ( ! is_array( $log ) ) {
			return array();
		}
		return array_slice( $log, 0, (int) $limit );
	}

	public static function clear_log() {
		delete_option( self::LOG_OPTION );
	}
}
